defmodule ExMoQ.RelayTest do
  use ExUnit.Case

  alias ExMoQ.Relay

  @moduletag :tmp_dir
  # muontrap logs an error whenever the relay exits, which several tests make it do.
  @moduletag capture_log: true

  # A stand-in relay: prints a line and stays up. It opens no socket: a test
  # passes the port of a listener it holds (`listener/0`) as `:internal`, and
  # the kernel accepts the readiness probe's connection on it.
  @fake_alive """
  #!/bin/sh
  echo "fake relay starting: $*"
  exec sleep 600
  """

  @fake_failing """
  #!/bin/sh
  echo "Error: cannot bind"
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

  # A listening socket owned by the test process, closed with it.
  defp listener do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    port
  end

  describe "args/1" do
    test "renders the listeners that are asked for" do
      assert Relay.args(quic: 4443, tcp: 4444, internal: 9101) == [
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
      assert Relay.args(
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

    test "every listener binds to :ip, and the web one may share the QUIC port" do
      assert Relay.args(ip: {0, 0, 0, 0}, quic: 4443, web: 4443, internal: nil) == [
               "--log-level",
               "warn",
               "--listen",
               "0.0.0.0:4443",
               "--web-http-listen",
               "0.0.0.0:4443",
               "--listen-tls-generate",
               "localhost",
               "--auth-public",
               "**"
             ]

      assert Relay.args(ip: {0, 0, 0, 0, 0, 0, 0, 1}, quic: nil, tcp: 1) ==
               ["--log-level", "warn", "--listen-tcp-bind", "[::1]:1", "--auth-public", "**"]
    end

    test "auth_public: nil grants nothing, leaving auth to extra args" do
      assert Relay.args(
               quic: nil,
               tcp: 1,
               auth_public: nil,
               args: ["--auth-public-subscribe", "anon/**"]
             ) == [
               "--log-level",
               "warn",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-public-subscribe",
               "anon/**"
             ]
    end
  end

  describe "find_binary/1" do
    test "prefers the option, then $MOQ_RELAY, then $PATH", %{tmp_dir: dir} do
      path = script!(dir, "moq-relay", @fake_silent)
      assert Relay.find_binary(binary: path) == path
      assert Relay.find_binary(binary: Path.join(dir, "missing")) == nil
    end
  end

  describe "start_link/1" do
    test "no listener asked for" do
      assert {:error, :no_listener} = Relay.start_link(quic: nil, tcp: nil, binary: "/bin/sh")
    end

    test "no binary", %{tmp_dir: dir} do
      assert {:error, :no_binary} = Relay.start_link(binary: Path.join(dir, "missing"))
    end

    test "a relay that exits before it is ready", %{tmp_dir: dir} do
      path = script!(dir, "failing", @fake_failing)

      # The status is usually 1, but a process this quick to exit can be
      # reported as a port error such as :epipe instead.
      assert {:error, {:exited, _status, ["Error: cannot bind"]}} =
               Relay.start_link(binary: path, log_output: nil)
    end

    test "a relay that never accepts connections", %{tmp_dir: dir} do
      path = script!(dir, "silent", @fake_silent)

      assert {:error, {:not_ready, 300, []}} =
               Relay.start_link(binary: path, ready_timeout: 300, log_output: nil)
    end

    test "a ready relay reports its ports, urls, output and exit", %{tmp_dir: dir} do
      path = script!(dir, "alive", @fake_alive)
      me = self()

      {:ok, relay} =
        Relay.start_link(
          binary: path,
          tcp: :auto,
          internal: listener(),
          on_output: &send(me, {:line, &1})
        )

      # Output arrives on its own; readiness does not wait for it here.
      assert_receive {:line, "fake relay starting: --log-level warn --listen" <> _}, 2_000

      %{ports: ports, alive?: true, exit_status: nil, binary: ^path} = Relay.status(relay)
      assert is_integer(ports.quic) and is_integer(ports.tcp) and is_integer(ports.internal)
      assert Relay.quic_url(relay) == "https://127.0.0.1:#{ports.quic}"
      assert Relay.web_url(relay) == nil
      assert Relay.tcp_url(relay) == "tcp://127.0.0.1:#{ports.tcp}"
      assert Relay.internal_url(relay) == "http://127.0.0.1:#{ports.internal}"

      # Killing the OS process is reported, and the GenServer stays (on_exit: :keep).
      os_pid = Relay.os_pid(relay)
      assert is_integer(os_pid)
      System.cmd("kill", [Integer.to_string(os_pid)])
      Process.sleep(300)
      assert %{alive?: false, exit_status: status} = Relay.status(relay)
      assert is_integer(status)
      assert :ok = Relay.stop(relay)
    end

    test "on_exit: :stop takes the GenServer down with the relay", %{tmp_dir: dir} do
      path = script!(dir, "alive", @fake_alive)
      Process.flag(:trap_exit, true)
      me = self()

      {:ok, relay} =
        Relay.start_link(
          binary: path,
          internal: listener(),
          on_output: &send(me, {:line, &1}),
          on_exit: :stop
        )

      # The relay is running once it has printed.
      assert_receive {:line, "fake relay starting: " <> _}, 2_000
      System.cmd("kill", [Integer.to_string(Relay.os_pid(relay))])
      assert_receive {:EXIT, ^relay, {:relay_exited, _}}, 2_000
    end
  end

  describe "a real moq-relay" do
    @describetag :relay

    test "starts with every listener, reports a version, and stops" do
      assert {:ok, version} = Relay.version()
      assert version =~ ~r/^\d+\.\d+\.\d+/

      {:ok, relay} = Relay.start_link(tcp: :auto, web: :auto, log_output: nil)
      %{alive?: true, ports: ports} = Relay.status(relay)
      assert is_integer(Relay.os_pid(relay))

      assert {200, _body} = get(ports.internal, "/health")
      assert {200, _body} = get(ports.web, "/health")
      # The SHA-256 of the generated certificate, hex-encoded.
      assert {200, fingerprint} = get(ports.web, "/certificate.sha256")
      assert String.trim(fingerprint) =~ ~r/^[0-9a-f]{64}$/

      assert :ok = Relay.stop(relay)
      refute Process.alive?(relay)
    end
  end

  defp get(port, path) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {url, []}, [timeout: 2_000], body_format: :binary)

    {status, body}
  end
end
