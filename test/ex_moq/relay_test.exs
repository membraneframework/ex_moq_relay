defmodule ExMoQ.RelayTest do
  use ExUnit.Case

  import ExMoQ.Testing.Relay, only: [free_port: 0]
  import ExUnit.CaptureLog

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Info

  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  describe "a fake relay" do
    @describetag :tmp_dir

    test "that exits before it is ready leaves no socket file", %{tmp_dir: dir} do
      binary =
        script!(dir, "failed", """
        #!/bin/sh
        echo "$NOTIFY_SOCKET"
        exit 1
        """)

      me = self()
      options = [binary: binary, log: {:warning, &send(me, &1)}]

      assert {:error, {:exit_status, 1}} = Relay.start(options)
      assert_receive path when is_binary(path)
      path = String.trim(path)

      assert String.ends_with?(path, ".sock")
      assert eventually(fn -> not File.exists?(path) end)
    end

    test "that exits cleanly before it is ready fails with exit status 0", %{tmp_dir: dir} do
      binary =
        script!(dir, "clean_start", """
        #!/bin/sh
        exit 0
        """)

      assert {:error, {:exit_status, 0}} = Relay.start(binary: binary, log: :none)
    end

    test "that exits cleanly once ready stops with exit status 0", %{tmp_dir: dir} do
      binary =
        script!(dir, "clean_exit", """
        #!/bin/sh
        echo "$NOTIFY_SOCKET"
        exec sleep 0.3
        """)

      ready = fn path ->
        {:ok, socket} = :gen_udp.open(0, [:local])
        :ok = :gen_udp.send(socket, {:local, String.trim(path)}, 0, "READY=1")
        :gen_udp.close(socket)
      end

      {:ok, relay} = Relay.start(binary: binary, log: {:warning, ready})
      ref = Process.monitor(relay)

      assert_receive {:DOWN, ^ref, :process, ^relay, {:exit_status, 0}}, 1_000
    end

    test "has invalid UTF-8 in its output replaced", %{tmp_dir: dir} do
      binary = script!(dir, "invalid", "#!/bin/sh\nprintf 'path \\303\\n'\nexit 1\n")

      log =
        capture_log(fn ->
          assert {:error, {:exit_status, 1}} = Relay.start(binary: binary)
        end)

      assert log =~ "[warning] moq-relay: path \uFFFD"
    end

    # `exec`, so the signal that stops a fake relay
    # reaches the process that would outlive it.
    @silent """
    #!/bin/sh
    exec sleep 60
    """

    test "that never reports readiness is stopped, and exits the caller", %{tmp_dir: dir} do
      options = [binary: script!(dir, "silent", @silent), ready_timeout: 300]

      {caller, ref} = spawn_monitor(fn -> Relay.start_link(options) end)
      assert_receive {:DOWN, ^ref, :process, ^caller, {:not_ready, 300}}, 1_000
    end

    test "given as a relative path is found", %{tmp_dir: dir} do
      path = script!(dir, "relative", @silent)
      resolved = path |> Path.relative_to_cwd() |> Relay.find_binary()
      assert resolved == path
    end

    test "has its output dropped with log: :none", %{tmp_dir: dir} do
      binary =
        script!(dir, "logging", """
        #!/bin/sh
        echo hello
        exit 1
        """)

      options = [binary: binary, log: :none]

      log = capture_log(fn -> assert {:error, {:exit_status, 1}} = Relay.start(options) end)
      refute log =~ "hello"
    end
  end

  describe "a real moq-relay" do
    @describetag :integration

    test "starts with every listener and stops" do
      [quic, tcp, internal] = Enum.map(1..3, fn _n -> free_port() end)

      options = [
        quic: quic,
        tcp: tcp,
        web: {quic, ip: {0, 0, 0, 0}},
        internal: internal,
        name: __MODULE__.Relay,
        log: :none
      ]

      {:ok, relay} = Relay.start_link(options)

      assert Process.whereis(__MODULE__.Relay) == relay

      info = Relay.info(relay)
      assert info.quic == {"https://127.0.0.1:#{quic}", :generated}
      assert info.tcp == "tcp://127.0.0.1:#{tcp}"
      assert info.web == "http://127.0.0.1:#{quic}"
      assert info.internal == "http://127.0.0.1:#{internal}"

      assert {200, _body} = get(info.internal <> "/health")
      assert {200, _body} = get(info.web <> "/health")
      # The SHA-256 of the generated certificate, hex-encoded.
      assert {200, fingerprint} = get(info.web <> "/certificate.sha256")
      assert String.trim(fingerprint) =~ ~r/^[0-9a-f]{64}$/

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", tcp, [:binary])
      :gen_tcp.close(socket)

      assert :ok = Relay.stop(__MODULE__.Relay)
      refute Process.alive?(relay)
    end

    test "logs at its :log level despite a RUST_LOG in the environment" do
      previous = System.get_env("RUST_LOG")
      System.put_env("RUST_LOG", "trace")

      on_exit(fn ->
        if previous, do: System.put_env("RUST_LOG", previous), else: System.delete_env("RUST_LOG")
      end)

      me = self()

      options = [quic: nil, tcp: free_port(), log: {:error, &send(me, {:line, &1})}]

      start_supervised!({Relay, options})
      refute_receive {:line, _line}, 500
    end

    test "a relay that binds its listeners but cannot authenticate is not ready" do
      options = [quic: nil, tcp: free_port(), auth: nil, log: :none]
      assert {:error, {:exit_status, 1}} = Relay.start(options)

      options = Keyword.put(options, :auth, subscribe: "**")
      assert %Info{} = Relay.info(start_supervised!({Relay, options}))
    end
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  defp get(url) do
    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 2_000], body_format: :binary)

    {status, body}
  end
end
