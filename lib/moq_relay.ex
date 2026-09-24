defmodule MoqRelay do
  @moduledoc """
  Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
  process: resolves the binary, picks free ports, renders the command line,
  waits until the relay accepts connections, and hands its output and exit
  status to the caller.

  The relay is a `MuonTrap.Daemon` under this GenServer, so the OS process
  dies with it. `start_link/1` returns only once the relay is ready, or
  `{:error, reason}` with the relay's first output lines when it is not.

      {:ok, relay} = MoqRelay.start_link(tcp: :auto)
      MoqRelay.tcp_url(relay)      #=> "tcp://127.0.0.1:54321"
      MoqRelay.quic_url(relay)     #=> "https://127.0.0.1:54322"
      MoqRelay.status(relay).alive?

  Or under a supervisor: `{MoqRelay, quic: 4443, internal: 9101}`.

  ## Options

    * `:binary` - path to the relay. Defaults to `$MOQ_RELAY`, then
      `moq-relay` on `$PATH` (`find_binary/1`).
    * `:quic` - the QUIC (UDP) listener: `:auto` for a free port (default),
      a port number, or `nil` for none.
    * `:tcp` - a plaintext qmux TCP listener, lossless: `:auto`, a port, or
      `nil` (default).
    * `:internal` - the internal HTTP listener with the ops endpoints
      (`/health`, `/metrics`, `/sessions`): `:auto` (default), a port, or `nil`.
    * `:tls_generate` - hostname for the generated certificate that the QUIC
      listener needs (default `"localhost"`); clients must disable
      verification or pin the fingerprint.
    * `:auth_public` - path patterns an anonymous session may publish and
      subscribe to, a string or a list (default `"**"`, everything).
    * `:log_level` - the relay's own log level (default `"warn"`).
    * `:args` - extra command-line arguments appended as given.
    * `:on_output` - a 1-arity function called with every output line. When
      absent, lines go to `Logger` at `:log_output` (default `:debug`, `nil`
      to drop them) with the prefix `moq-relay: `.
    * `:ready` - which listener to probe before returning: `:internal`,
      `:tcp` or `:none`. Defaults to the internal listener when there is
      one, else the TCP one, else `:none`. The QUIC listener cannot be probed.
    * `:ready_timeout` - milliseconds to wait for readiness (default 15 000).
    * `:on_exit` - what to do when the relay exits on its own: `:keep`
      (default) keeps the GenServer alive with `status/1` reporting the exit,
      `:stop` stops it with `{:relay_exited, status}` so a supervisor
      restarts it.
    * `:name` - a GenServer name.

  ## Relay versions

  The command line is that of moq-relay 0.14.18 (moq-dev `927051b50`) and
  later: `--listen`, `--listen-tcp-bind`, `--listen-tls-generate`,
  `--internal-listen`, `--auth-public` with patterns. A relay that rejects
  the flags as renamed makes `start_link/1` return
  `{:error, {:renamed_flags, lines}}`. `version/1` reads the binary's version.
  """

  use GenServer

  require Logger

  @default_ready_timeout_ms 15_000
  @probe_interval_ms 100
  @kept_lines 50

  @type port_option :: :auto | :inet.port_number() | nil

  @type option ::
          {:binary, Path.t()}
          | {:quic, port_option()}
          | {:tcp, port_option()}
          | {:internal, port_option()}
          | {:tls_generate, String.t() | nil}
          | {:auth_public, String.t() | [String.t()]}
          | {:log_level, String.t()}
          | {:args, [String.t()]}
          | {:on_output, (String.t() -> any()) | nil}
          | {:log_output, Logger.level() | nil}
          | {:ready, :internal | :tcp | :none}
          | {:ready_timeout, non_neg_integer()}
          | {:on_exit, :keep | :stop}
          | {:name, GenServer.name()}

  @type ports :: %{
          quic: :inet.port_number() | nil,
          tcp: :inet.port_number() | nil,
          internal: :inet.port_number() | nil
        }

  @type status :: %{
          alive?: boolean(),
          exit_status: integer() | nil,
          os_pid: non_neg_integer() | nil,
          ports: ports(),
          binary: Path.t()
        }

  @typedoc """
  Why the relay did not start: no binary, no listener asked for, it exited
  (with its first output lines), it rejected the flags as renamed, or it did
  not accept connections in time.
  """
  @type start_error ::
          :no_binary
          | :no_listener
          | {:exited, integer() | term(), [String.t()]}
          | {:renamed_flags, [String.t()]}
          | {:not_ready, non_neg_integer(), [String.t()]}

  @doc """
  Starts a relay, blocks until it is ready, and links it to the caller.

  A relay that does not start is reported as `{:error, reason}` without an
  exit signal to the caller (the link is made once the relay is ready), so
  the failure can be handled inline as well as by a supervisor.
  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, start_error() | term()}
  def start_link(opts \\ []) do
    case GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Resolves the relay binary: the `:binary` option, then `$MOQ_RELAY`, then
  `moq-relay` on `$PATH`; `nil` when none is an executable.
  """
  @spec find_binary(keyword()) :: Path.t() | nil
  def find_binary(opts \\ []) do
    System.find_executable(opts[:binary] || System.get_env("MOQ_RELAY") || "moq-relay")
  end

  @doc """
  The version the binary reports, e.g. `"0.14.18-927051b50"`.
  """
  @spec version(Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def version(binary \\ find_binary()) do
    with path when is_binary(path) <- binary || {:error, :no_binary},
         {out, 0} <- System.cmd(path, ["--help"], stderr_to_stdout: true),
         [line | _] <- String.split(out, "\n"),
         ["moq-relay", version] <- String.split(String.trim(line), " ", parts: 2) do
      {:ok, version}
    else
      {:error, _} = e -> e
      {out, status} when is_integer(status) -> {:error, {:exit_status, status, out}}
      other -> {:error, {:unexpected_output, other}}
    end
  end

  @doc """
  The relay's command line for the given listeners, with the ports already
  chosen (`:auto` is not resolved here). Exposed so a caller can see or test
  what will be run.
  """
  @spec args(keyword()) :: [String.t()]
  def args(opts) do
    listen = fn
      _flag, nil -> []
      flag, port -> [flag, "127.0.0.1:#{port}"]
    end

    auth =
      case Keyword.get(opts, :auth_public, "**") do
        list when is_list(list) -> Enum.join(list, ",")
        string -> string
      end

    tls =
      case {Keyword.get(opts, :quic), Keyword.get(opts, :tls_generate, "localhost")} do
        {nil, _} -> []
        {_, nil} -> []
        {_, host} -> ["--listen-tls-generate", host]
      end

    ["--log-level", Keyword.get(opts, :log_level, "warn")] ++
      listen.("--listen", Keyword.get(opts, :quic)) ++
      listen.("--listen-tcp-bind", Keyword.get(opts, :tcp)) ++
      listen.("--internal-listen", Keyword.get(opts, :internal)) ++
      tls ++
      ["--auth-public", auth] ++
      Keyword.get(opts, :args, [])
  end

  @spec status(GenServer.server()) :: status()
  def status(relay), do: GenServer.call(relay, :status)

  @spec ports(GenServer.server()) :: ports()
  def ports(relay), do: status(relay).ports

  @doc "`https://127.0.0.1:port` of the QUIC listener, or `nil`; append the path yourself."
  @spec quic_url(GenServer.server()) :: String.t() | nil
  def quic_url(relay), do: url("https", ports(relay).quic)

  @doc "`tcp://127.0.0.1:port` of the plaintext TCP listener, or `nil`."
  @spec tcp_url(GenServer.server()) :: String.t() | nil
  def tcp_url(relay), do: url("tcp", ports(relay).tcp)

  @doc "`http://127.0.0.1:port` of the internal listener (`/health`, `/metrics`), or `nil`."
  @spec internal_url(GenServer.server()) :: String.t() | nil
  def internal_url(relay), do: url("http", ports(relay).internal)

  @doc "The OS pid of the relay process itself (not the muontrap wrapper), or `nil`."
  @spec os_pid(GenServer.server()) :: non_neg_integer() | nil
  def os_pid(relay), do: status(relay).os_pid

  @doc "Stops the relay and this process."
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(relay, timeout \\ 5_000), do: GenServer.stop(relay, :normal, timeout)

  ## GenServer

  @impl true
  def init(opts) do
    with binary when is_binary(binary) <- find_binary(opts) || :no_binary,
         ports = %{
           quic: resolve_port(Keyword.get(opts, :quic, :auto), :udp),
           tcp: resolve_port(Keyword.get(opts, :tcp), :tcp),
           internal: resolve_port(Keyword.get(opts, :internal, :auto), :tcp)
         },
         true <- (ports.quic != nil or ports.tcp != nil) || :no_listener do
      me = self()

      daemon_opts = [
        stderr_to_stdout: true,
        logger_fun: fn line -> send(me, {:moq_relay_output, line}) end,
        exit_status_to_reason: &{:exit_status, &1}
      ]

      args = args(Keyword.merge(opts, quic: ports.quic, tcp: ports.tcp, internal: ports.internal))
      Process.flag(:trap_exit, true)
      {:ok, daemon} = MuonTrap.Daemon.start_link(binary, args, daemon_opts)

      state = %{
        binary: binary,
        daemon: daemon,
        ports: ports,
        os_pid: nil,
        exit_status: nil,
        on_output: Keyword.get(opts, :on_output),
        log_output: Keyword.get(opts, :log_output, :debug),
        on_exit: Keyword.get(opts, :on_exit, :keep),
        head: []
      }

      ready_port =
        case Keyword.get(opts, :ready, default_ready(ports)) do
          :internal -> ports.internal
          :tcp -> ports.tcp
          :none -> nil
        end

      timeout = Keyword.get(opts, :ready_timeout, @default_ready_timeout_ms)

      case await_ready(state, ready_port, System.monotonic_time(:millisecond) + timeout, timeout) do
        {:ok, state} ->
          {:ok, %{state | os_pid: relay_os_pid(daemon)}}

        {:error, reason, state} ->
          if Process.alive?(state.daemon), do: GenServer.stop(state.daemon)
          {:stop, reason}
      end
    else
      :no_binary -> {:stop, :no_binary}
      :no_listener -> {:stop, :no_listener}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       alive?: state.exit_status == nil and Process.alive?(state.daemon),
       exit_status: state.exit_status,
       os_pid: state.os_pid,
       ports: state.ports,
       binary: state.binary
     }, state}
  end

  @impl true
  def handle_info({:moq_relay_output, line}, state), do: {:noreply, output(state, line)}

  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) do
    status =
      case reason do
        {:exit_status, status} -> status
        _ -> -1
      end

    state = %{state | exit_status: status}

    case state.on_exit do
      :stop -> {:stop, {:relay_exited, status}, state}
      :keep -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: daemon}) do
    if Process.alive?(daemon), do: GenServer.stop(daemon)
    :ok
  end

  ## Readiness

  defp default_ready(%{internal: internal, tcp: tcp}) do
    cond do
      internal != nil -> :internal
      tcp != nil -> :tcp
      true -> :none
    end
  end

  defp await_ready(state, nil, _deadline, _timeout), do: {:ok, state}

  # Output and the daemon's exit are handled here too, since init/1 cannot
  # rely on handle_info/2 yet.
  defp await_ready(state, port, deadline, timeout) do
    receive do
      {:moq_relay_output, line} ->
        await_ready(output(state, line), port, deadline, timeout)

      {:EXIT, daemon, reason} when daemon == state.daemon ->
        {:error, exit_reason(reason, state), %{state | exit_status: -1}}
    after
      @probe_interval_ms ->
        cond do
          probe(port) ->
            {:ok, state}

          System.monotonic_time(:millisecond) > deadline ->
            {:error, {:not_ready, timeout, head(state)}, state}

          true ->
            await_ready(state, port, deadline, timeout)
        end
    end
  end

  defp exit_reason(reason, state) do
    lines = head(state)
    status = with {:exit_status, s} <- reason, do: s

    if Enum.any?(lines, &String.contains?(&1, "were renamed")),
      do: {:renamed_flags, lines},
      else: {:exited, status, lines}
  end

  defp probe(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  ## Output

  defp output(state, line) do
    line = line |> IO.chardata_to_string() |> String.trim_trailing()

    case state do
      %{on_output: fun} when is_function(fun, 1) -> fun.(line)
      %{log_output: nil} -> :ok
      %{log_output: level} -> Logger.log(level, ["moq-relay: ", line])
    end

    if length(state.head) < @kept_lines,
      do: %{state | head: [line | state.head]},
      else: state
  end

  defp head(state), do: Enum.reverse(state.head)

  ## Ports and pids

  defp resolve_port(nil, _kind), do: nil
  defp resolve_port(port, _kind) when is_integer(port), do: port

  defp resolve_port(:auto, :udp) do
    {:ok, socket} = :gen_udp.open(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  defp resolve_port(:auto, :tcp) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # `MuonTrap.Daemon.os_pid/1` is the muontrap wrapper; the relay is its child.
  defp relay_os_pid(daemon) do
    with wrapper when is_integer(wrapper) <- MuonTrap.Daemon.os_pid(daemon),
         {out, 0} <-
           System.cmd("pgrep", ["-P", Integer.to_string(wrapper)], stderr_to_stdout: true),
         {child, _} <-
           out |> String.trim() |> String.split("\n") |> List.first() |> Integer.parse() do
      child
    else
      _ -> nil
    end
  end

  defp url(_scheme, nil), do: nil
  defp url(scheme, port), do: "#{scheme}://127.0.0.1:#{port}"
end
