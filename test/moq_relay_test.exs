defmodule MoqRelayTest do
  use ExUnit.Case

  @moduletag :tmp_dir
  # muontrap logs an error whenever the relay exits, which several tests make it do.
  @moduletag capture_log: true

  # A stand-in relay: prints a line, then serves the internal listener's port
  # with nc so the readiness probe succeeds, forever.
  @fake_listener """
  #!/bin/sh
  echo "fake relay starting: $*"
  while [ $# -gt 0 ]; do
    case "$1" in --internal-listen) addr="$2"; shift;; esac
    shift
  done
  port="${addr##*:}"
  while true; do nc -l 127.0.0.1 "$port" >/dev/null 2>&1 || sleep 0.1; done
  """

  @fake_renamed """
  #!/bin/sh
  echo "Error: these settings were renamed and are no longer applied; update them and try again:"
  echo "  --server-bind / MOQ_SERVER_BIND -> --listen / MOQ_LISTEN"
  exit 1
  """

  @fake_silent """
  #!/bin/sh
  sleep 60
  """

  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  describe "args/1" do
    test "renders the listeners that are asked for" do
      assert MoqRelay.args(quic: 4443, tcp: 4444, internal: 9101) == [
               "--log-level",
               "warn",
               "--listen",
               "127.0.0.1:4443",
               "--listen-tcp-bind",
               "127.0.0.1:4444",
               "--internal-listen",
               "127.0.0.1:9101",
               "--listen-tls-generate",
               "localhost",
               "--auth-public",
               "**"
             ]
    end

    test "a TCP-only relay needs no certificate; patterns and extra args pass through" do
      assert MoqRelay.args(
               quic: nil,
               tcp: 1,
               log_level: "info",
               auth_public: ["anon/**", "demo/**"],
               args: ["--stats-enabled"]
             ) == [
               "--log-level",
               "info",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-public",
               "anon/**,demo/**",
               "--stats-enabled"
             ]
    end
  end

  describe "find_binary/1" do
    test "prefers the option, then $MOQ_RELAY, then $PATH", %{tmp_dir: dir} do
      path = script!(dir, "moq-relay", @fake_silent)
      assert MoqRelay.find_binary(binary: path) == path
      assert MoqRelay.find_binary(binary: Path.join(dir, "missing")) == nil
    end
  end

  describe "start_link/1" do
    test "no listener asked for" do
      assert {:error, :no_listener} = MoqRelay.start_link(quic: nil, tcp: nil, binary: "/bin/sh")
    end

    test "no binary", %{tmp_dir: dir} do
      assert {:error, :no_binary} = MoqRelay.start_link(binary: Path.join(dir, "missing"))
    end

    test "a relay that rejects the flags as renamed", %{tmp_dir: dir} do
      path = script!(dir, "renamed", @fake_renamed)

      assert {:error, {:renamed_flags, lines}} =
               MoqRelay.start_link(binary: path, log_output: nil)

      assert Enum.any?(lines, &String.contains?(&1, "--server-bind"))
    end

    test "a relay that never accepts connections", %{tmp_dir: dir} do
      path = script!(dir, "silent", @fake_silent)

      assert {:error, {:not_ready, 300, []}} =
               MoqRelay.start_link(binary: path, ready_timeout: 300, log_output: nil)
    end

    test "a ready relay reports its ports, urls, output and exit", %{tmp_dir: dir} do
      path = script!(dir, "listener", @fake_listener)
      me = self()

      {:ok, relay} =
        MoqRelay.start_link(binary: path, tcp: :auto, on_output: &send(me, {:line, &1}))

      assert_receive {:line, "fake relay starting: --log-level warn --listen" <> _}

      %{ports: ports, alive?: true, exit_status: nil, binary: ^path} = MoqRelay.status(relay)
      assert is_integer(ports.quic) and is_integer(ports.tcp) and is_integer(ports.internal)
      assert MoqRelay.quic_url(relay) == "https://127.0.0.1:#{ports.quic}"
      assert MoqRelay.tcp_url(relay) == "tcp://127.0.0.1:#{ports.tcp}"
      assert MoqRelay.internal_url(relay) == "http://127.0.0.1:#{ports.internal}"

      # Killing the OS process is reported, and the GenServer stays (on_exit: :keep).
      os_pid = MoqRelay.os_pid(relay)
      assert is_integer(os_pid)
      System.cmd("kill", [Integer.to_string(os_pid)])
      Process.sleep(300)
      assert %{alive?: false, exit_status: status} = MoqRelay.status(relay)
      assert is_integer(status)
      assert :ok = MoqRelay.stop(relay)
    end

    test "on_exit: :stop takes the GenServer down with the relay", %{tmp_dir: dir} do
      path = script!(dir, "listener", @fake_listener)
      Process.flag(:trap_exit, true)
      {:ok, relay} = MoqRelay.start_link(binary: path, log_output: nil, on_exit: :stop)
      System.cmd("kill", [Integer.to_string(MoqRelay.os_pid(relay))])
      assert_receive {:EXIT, ^relay, {:relay_exited, _}}, 2_000
    end
  end

  describe "a real moq-relay" do
    @describetag :relay

    test "starts with every listener, reports a version, and stops" do
      assert {:ok, version} = MoqRelay.version()
      assert version =~ ~r/^\d+\.\d+\.\d+/

      {:ok, relay} = MoqRelay.start_link(tcp: :auto, log_output: nil)
      %{alive?: true, ports: ports} = MoqRelay.status(relay)
      assert is_integer(MoqRelay.os_pid(relay))

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", ports.internal, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /health HTTP/1.0\r\n\r\n")
      {:ok, reply} = :gen_tcp.recv(socket, 0, 2_000)
      assert reply =~ "HTTP/1."
      :gen_tcp.close(socket)

      assert :ok = MoqRelay.stop(relay)
      refute Process.alive?(relay)
    end
  end
end
