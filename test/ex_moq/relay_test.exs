defmodule ExMoQ.RelayTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Config

  @moduletag :tmp_dir

  # A stand-in relay: prints a line and stays up until `stop` exists, then
  # exits with status 3. It opens no socket: a test passes the port of a
  # listener it holds (`listener/0`) as `:internal`, and the kernel accepts
  # the readiness probe's connection on it.
  defp fake_alive(stop) do
    """
    #!/bin/sh
    echo "fake relay starting: $*"
    while [ ! -e "#{stop}" ]; do sleep 0.05; done
    exit 3
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

  # Any executable will do where the relay is not run.
  defp config!(opts), do: Config.new!([binary: "/bin/sh"] ++ opts)

  # A listening socket owned by the test process, closed with it.
  defp listener() do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    port
  end

  describe "args/1" do
    test "renders the listeners that are asked for" do
      assert Relay.args(config!(quic: 4443, tcp: 4444, internal: 9101)) == [
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
               config!(
                 quic: nil,
                 tcp: 1,
                 internal: nil,
                 log_level: "info",
                 auth_public: ["anon/**", "demo/**"],
                 args: ["--stats-enabled"]
               )
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
      assert Relay.args(config!(ip: {0, 0, 0, 0}, quic: 4443, web: 4443, internal: nil)) == [
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

      assert Relay.args(config!(ip: {0, 0, 0, 0, 0, 0, 0, 1}, quic: nil, tcp: 1, internal: nil)) ==
               ["--log-level", "warn", "--listen-tcp-bind", "[::1]:1", "--auth-public", "**"]
    end

    test "auth_public: nil grants nothing, leaving auth to extra args" do
      assert Relay.args(
               config!(
                 quic: nil,
                 tcp: 1,
                 internal: nil,
                 auth_public: nil,
                 args: ["--auth-public-subscribe", "anon/**"]
               )
             ) == [
               "--log-level",
               "warn",
               "--listen-tcp-bind",
               "127.0.0.1:1",
               "--auth-public-subscribe",
               "anon/**"
             ]
    end

    test "the QUIC listener carries the host of its generated certificate, or none" do
      assert Relay.args(config!(quic: {4443, tls_generate: "relay.test"}, internal: nil)) ==
               [
                 "--log-level",
                 "warn",
                 "--listen",
                 "127.0.0.1:4443",
                 "--listen-tls-generate",
                 "relay.test",
                 "--auth-public",
                 "**"
               ]

      assert Relay.args(config!(quic: {4443, tls_generate: nil}, internal: nil)) ==
               ["--log-level", "warn", "--listen", "127.0.0.1:4443", "--auth-public", "**"]
    end
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
      config = Config.new!(binary: script!(dir, "failing", @fake_failing))

      log =
        capture_log(fn ->
          assert {:error, {{:exited, {:exit_status, 1}}, _child}} =
                   start_supervised({Relay, config})
        end)

      assert log =~ "moq-relay: Error: cannot bind"
    end

    test "a relay that never accepts connections is stopped", %{tmp_dir: dir} do
      path = script!(dir, "silent", @fake_silent)
      config = Config.new!(binary: path, ready_timeout: 300)

      assert {:error, {:not_ready, 300}} = Relay.start_link(config)
    end

    test "a ready relay runs with the config's ports, and exits with its status",
         %{tmp_dir: dir} do
      stop = Path.join(dir, "stop")
      me = self()

      config =
        Config.new!(
          binary: script!(dir, "alive", fake_alive(stop)),
          tcp: :auto,
          internal: listener(),
          output: &send(me, {:line, &1})
        )

      relay = start_supervised!(Supervisor.child_spec({Relay, config}, restart: :temporary))
      {quic, _tls} = config.quic

      assert_receive {:line, line}, 2_000
      assert line == "fake relay starting: " <> Enum.join(Relay.args(config), " ")
      assert Relay.quic_url(config) == "https://127.0.0.1:#{quic}"
      assert Relay.tcp_url(config) == "tcp://127.0.0.1:#{config.tcp}"
      assert Relay.internal_url(config) == "http://127.0.0.1:#{config.internal}"
      assert Relay.web_url(config) == nil

      ref = Process.monitor(relay)
      File.touch!(stop)
      assert_receive {:DOWN, ^ref, :process, ^relay, {:exit_status, 3}}, 2_000
    end

    test ":name registers the relay's process", %{tmp_dir: dir} do
      config =
        Config.new!(
          binary: script!(dir, "alive", fake_alive(Path.join(dir, "stop"))),
          internal: listener(),
          name: __MODULE__.Named
        )

      {:ok, relay} = Relay.start_link(config)
      assert Process.whereis(__MODULE__.Named) == relay
      assert :ok = Relay.stop(__MODULE__.Named)
    end
  end

  describe "a real moq-relay" do
    @describetag :integration

    test "starts with every listener, reports a version, and stops" do
      assert {:ok, version} = Relay.version()
      assert version =~ ~r/^\d+\.\d+\.\d+/

      config = Config.new!(tcp: :auto, web: :auto, output: nil)
      {:ok, relay} = Relay.start_link(config)

      assert {200, _body} = get(config.internal, "/health")
      assert {200, _body} = get(config.web, "/health")
      # The SHA-256 of the generated certificate, hex-encoded.
      assert {200, fingerprint} = get(config.web, "/certificate.sha256")
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
