defmodule ExMoQ.RelayTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Info

  @moduletag :tmp_dir

  # A stand-in relay: reports readiness, then the TCP port it "bound" for
  # `--listen-tcp-bind 127.0.0.1:0` (after the readiness, which the logs can
  # trail), and stays up until `stop` exists, then exits with status 3.
  defp fake_alive(stop) do
    """
    #!/usr/bin/env elixir
    IO.puts("fake relay starting: " <> Enum.join(System.argv(), " "))
    IO.puts("RUST_LOG=" <> System.get_env("RUST_LOG", ""))
    {:ok, socket} = :gen_udp.open(0, [:local])
    :ok = :gen_udp.send(socket, {:local, System.fetch_env!("NOTIFY_SOCKET")}, 0, "READY=1\\n")
    Process.sleep(100)
    IO.puts("2026-10-01T00:00:00.000000Z  INFO moq_tokio::server: listening (tcp) addr=127.0.0.1:4321")
    IO.puts("2026-10-01T00:00:00.000000Z  WARN moq_relay::web: a warning")
    Stream.repeatedly(fn -> Process.sleep(50) end) |> Enum.find(fn _ -> File.exists?("#{stop}") end)
    System.halt(3)
    """
  end

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

  defp free_port() do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  describe "find_binary/1" do
    test "resolves the :binary option", %{tmp_dir: dir} do
      path = script!(dir, "moq-relay", @fake_silent)
      assert Relay.find_binary(path) == path
      assert Relay.find_binary(Path.join(dir, "missing")) == nil
    end
  end

  describe "start_link/1" do
    test "a relay that exits before it is ready reports its exit and logs its output",
         %{tmp_dir: dir} do
      options = %Relay{binary: script!(dir, "failing", @fake_failing)}

      log =
        capture_log(fn ->
          assert {:error, {{:exit_status, 1}, _child}} =
                   start_supervised({Relay, options})
        end)

      assert log =~ "moq-relay: Error: cannot bind"
    end

    test "start/1 returns the exit of a relay that exits before it is ready, and its output",
         %{tmp_dir: dir} do
      me = self()

      options =
        %Relay{
          binary: script!(dir, "failing", @fake_failing),
          output: &send(me, {:line, &1})
        }

      assert {:error, {:exit_status, 1}} = Relay.start(options)
      assert_received {:line, "Error: cannot bind"}
    end

    test "a relay that never reports readiness is stopped", %{tmp_dir: dir} do
      path = script!(dir, "silent", @fake_silent)
      options = %Relay{binary: path, ready_timeout: 300}

      assert {:error, {:not_ready, 300}} = Relay.start_link(options)
    end

    test "a ready relay reports the ports it bound, and exits with its status",
         %{tmp_dir: dir} do
      stop = Path.join(dir, "stop")
      me = self()

      options =
        %Relay{
          binary: script!(dir, "alive", fake_alive(stop)),
          quic: nil,
          tcp: :auto,
          output: &send(me, {:line, &1})
        }

      relay = start_supervised!(Supervisor.child_spec({Relay, options}, restart: :temporary))

      assert %Info{tcp_url: "tcp://127.0.0.1:4321", quic_url: nil} = Relay.info(relay)
      assert_received {:line, "fake relay starting: " <> args}
      assert args == Enum.join(Relay.args(options), " ")

      # The info line with the port is asked for, but is below `"warn"`.
      assert_received {:line,
                       "RUST_LOG=warn,moq_relay::relay=info,moq_relay::web=info,moq_tokio::server=info"}

      assert_receive {:line, "2026-10-01T00:00:00.000000Z  WARN moq_relay::web: a warning"}
      refute_received {:line, "2026-10-01T00:00:00.000000Z  INFO" <> _line}

      ref = Process.monitor(relay)
      File.touch!(stop)
      assert_receive {:DOWN, ^ref, :process, ^relay, {:exit_status, 3}}, 5_000
    end

    test ":name registers the relay's process", %{tmp_dir: dir} do
      options =
        %Relay{
          binary: script!(dir, "alive", fake_alive(Path.join(dir, "stop"))),
          quic: nil,
          tcp: :auto,
          name: __MODULE__.Named
        }

      {:ok, relay} = Relay.start_link(options)
      assert Process.whereis(__MODULE__.Named) == relay
      assert :ok = Relay.stop(__MODULE__.Named)
    end
  end

  describe "a real moq-relay" do
    @describetag :integration

    test "starts with every listener, reports a version, and stops" do
      assert {:ok, version} = Relay.version()
      assert version =~ ~r/^\d+\.\d+\.\d+/

      internal = free_port()
      options = %Relay{tcp: :auto, web: :auto, internal: internal, output: nil}
      {:ok, relay} = Relay.start_link(options)

      info = Relay.info(relay)
      assert info.internal_url == "http://127.0.0.1:#{internal}"
      assert %URI{scheme: "https", port: quic} = URI.parse(info.quic_url)
      assert %URI{scheme: "tcp", port: tcp} = URI.parse(info.tcp_url)
      assert quic in 1..65_535
      assert info.tls == :generated

      assert {200, _body} = get(info.internal_url <> "/health")
      assert {200, _body} = get(info.web_url <> "/health")
      # The SHA-256 of the generated certificate, hex-encoded.
      assert {200, fingerprint} = get(info.web_url <> "/certificate.sha256")
      assert String.trim(fingerprint) =~ ~r/^[0-9a-f]{64}$/

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", tcp, [:binary])
      :gen_tcp.close(socket)

      assert :ok = Relay.stop(relay)
      refute Process.alive?(relay)
    end

    test "a relay that binds its listeners but cannot authenticate is not ready" do
      options = %Relay{tcp: :auto, auth_public: nil, output: nil}
      assert {:error, {:exit_status, 1}} = Relay.start(options)
    end
  end

  defp get(url) do
    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 2_000], body_format: :binary)

    {status, body}
  end
end
