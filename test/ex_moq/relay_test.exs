defmodule ExMoQ.RelayTest do
  use ExUnit.Case

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Info

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

  test "find_binary/1 resolves an executable path" do
    assert Relay.find_binary("/bin/sh") == "/bin/sh"
    assert Relay.find_binary("/nonexistent/moq-relay") == nil
  end

  test "version/1 is an error without a binary" do
    assert Relay.version("/nonexistent/moq-relay") == {:error, :no_binary}
  end

  @tag :tmp_dir
  test "a relay that never reports readiness is stopped, and exits the caller", %{tmp_dir: dir} do
    options = %Relay{binary: script!(dir, "silent", @fake_silent), ready_timeout: 300}

    {caller, ref} = spawn_monitor(fn -> Relay.start_link(options) end)
    assert_receive {:DOWN, ^ref, :process, ^caller, {:not_ready, 300}}, 1_000
  end

  describe "a real moq-relay" do
    @describetag :integration

    test "starts with every listener, reports a version, and stops" do
      assert {:ok, version} = Relay.version()
      assert version =~ ~r/^\d+\.\d+\.\d+/

      internal = free_port()
      options = %Relay{tcp: :auto, web: :auto, internal: internal, name: __MODULE__.Relay, output: nil}
      {:ok, relay} = Relay.start_link(options)

      assert Process.whereis(__MODULE__.Relay) == relay

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

      assert :ok = Relay.stop(__MODULE__.Relay)
      refute Process.alive?(relay)
    end

    test "reports the ports it bound despite a RUST_LOG in the environment" do
      previous = System.get_env("RUST_LOG")
      System.put_env("RUST_LOG", "error")

      on_exit(fn ->
        if previous, do: System.put_env("RUST_LOG", previous), else: System.delete_env("RUST_LOG")
      end)

      options = %Relay{quic: nil, tcp: :auto, log_level: "info", output: nil}
      relay = start_supervised!({Relay, options})
      assert %Info{tcp_url: "tcp://127.0.0.1:" <> _port} = Relay.info(relay)
    end

    test "binds a listener to an :ip of its own, and reports the port it bound there" do
      me = self()

      options =
        %Relay{
          quic: nil,
          tcp: :auto,
          web: {:auto, ip: {0, 0, 0, 0}},
          log_level: "info",
          output: &send(me, {:line, &1})
        }

      info = Relay.info(start_supervised!({Relay, options}))
      assert %URI{host: "127.0.0.1", port: tcp} = URI.parse(info.tcp_url)
      assert %URI{host: "127.0.0.1", port: web} = URI.parse(info.web_url)
      assert {200, _body} = get(info.web_url <> "/health")

      {:messages, messages} = Process.info(self(), :messages)
      lines = for {:line, line} <- messages, do: line
      assert Enum.any?(lines, &(&1 =~ "listening (tcp) addr=127.0.0.1:#{tcp}"))
      assert Enum.any?(lines, &(&1 =~ ~s(listening addr=0.0.0.0:#{web} kind="http")))
    end

    test "a relay that binds its listeners but cannot authenticate is not ready" do
      me = self()
      options = %Relay{tcp: :auto, auth: nil, output: &send(me, {:line, &1})}
      assert {:error, {:exit_status, 1}} = Relay.start(options)
      assert_received {:line, _line}

      options = %Relay{options | auth: [subscribe: "**"], output: nil}
      assert %Info{} = Relay.info(start_supervised!({Relay, options}))
    end
  end

  defp get(url) do
    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 2_000], body_format: :binary)

    {status, body}
  end
end
