defmodule ExMoQ.Relay do
  @moduledoc """
  Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
  process: resolves the binary, picks free ports, renders the command line,
  waits until the relay accepts connections, and hands its output and exit
  status to the caller.

  The relay is a `MuonTrap.Daemon` under this GenServer, so the OS process
  dies with it. `start_link/1` returns only once the relay is ready, or
  `{:error, reason}` with the relay's first output lines when it is not.

      {:ok, relay} = ExMoQ.Relay.start_link(tcp: :auto, web: :auto)
      ExMoQ.Relay.tcp_url(relay)      #=> "tcp://127.0.0.1:54321"
      ExMoQ.Relay.quic_url(relay)     #=> "https://127.0.0.1:54322"
      ExMoQ.Relay.web_url(relay)      #=> "http://127.0.0.1:54323"
      ExMoQ.Relay.status(relay).alive?

  Or under a supervisor: `{ExMoQ.Relay, quic: 4443, web: 4443, internal: 9101}`.

  ## Options

    * `:binary` - path to the relay. Defaults to `$MOQ_RELAY`, then
      `moq-relay` on `$PATH` (`find_binary/1`).
    * `:ip` - the address every listener binds to, an `:inet` tuple (default
      `{127, 0, 0, 1}`). With the any-address (`{0, 0, 0, 0}` or
      `{0, 0, 0, 0, 0, 0, 0, 0}`) the readiness probe and the `*_url`
      functions use loopback.
    * `:quic` - the QUIC (UDP) listener: `:auto` for a free port (default),
      a port number, or `nil` for none.
    * `:tcp` - a plaintext qmux TCP listener, lossless: `:auto`, a port, or
      `nil` (default).
    * `:web` - the web HTTP listener (`--web-http-listen`), which serves
      `/health`, `/certificate.sha256` (for browsers pinning the generated
      certificate), `/fetch` and WebSocket connections: `:auto`, a port, or
      `nil` (default). It is TCP, so it can share its port number with the
      QUIC listener.
    * `:internal` - the internal HTTP listener with the ops endpoints
      (`/health`, `/metrics`, `/sessions`): `:auto` (default), a port, or `nil`.
    * `:tls_generate` - hostname for the generated certificate that the QUIC
      listener needs (default `"localhost"`); clients must disable
      verification or pin the fingerprint.
    * `:auth_public` - path patterns an anonymous session may publish and
      subscribe to, a string or a list. The default, `"**"` (everything), is
      meant for tests and local use.
    * `:log_level` - the relay's own log level (default `"warn"`).
    * `:args` - extra command-line arguments appended as given.
    * `:on_output` - a 1-arity function called with every output line. When
      absent, lines go to `Logger` at `:log_output` (default `:debug`, `nil`
      to drop them) with the prefix `moq-relay: `.
    * `:ready` - which listener to probe before returning: `:internal`,
      `:web`, `:tcp` or `:none`. Defaults to the first of those that is
      enabled. The QUIC listener cannot be probed.
    * `:ready_timeout` - milliseconds to wait for readiness (default 15 000).
    * `:on_exit` - what to do when the relay exits on its own: `:keep`
      (default) keeps the GenServer alive with `status/1` reporting the exit,
      `:stop` stops it with `{:relay_exited, status}` so a supervisor
      restarts it.
    * `:name` - a GenServer name.

  ## Caveats

    * `:auto` picks a port by opening a socket on port 0 and closing it, so
      another process can take the port before the relay binds it.
    * `os_pid/1` finds the relay under the muontrap wrapper with `pgrep`, so
      it works on macOS and Linux only.

  ## Relay versions

  The command line is that of moq-relay 0.15.0 (moq-dev `24ab8faa3`) and
  later: `--listen`, `--listen-tcp-bind`, `--listen-tls-generate`,
  `--web-http-listen`, `--internal-listen`, `--auth-public` with patterns.
  Older relays are not supported.
  """

  use GenServer

  require Logger

  @default_ready_timeout_ms 15_000
  @probe_interval_ms 100
  @kept_lines 50

  @type port_option :: :auto | :inet.port_number() | nil

  @type option ::
          {:binary, Path.t()}
          | {:ip, :inet.ip_address()}
          | {:quic, port_option()}
          | {:tcp, port_option()}
          | {:web, port_option()}
          | {:internal, port_option()}
          | {:tls_generate, String.t() | nil}
          | {:auth_public, String.t() | [String.t()]}
          | {:log_level, String.t()}
          | {:args, [String.t()]}
          | {:on_output, (String.t() -> any()) | nil}
          | {:log_output, Logger.level() | nil}
          | {:ready, :internal | :web | :tcp | :none}
          | {:ready_timeout, non_neg_integer()}
          | {:on_exit, :keep | :stop}
          | {:name, GenServer.name()}

  @type ports :: %{
          quic: :inet.port_number() | nil,
          tcp: :inet.port_number() | nil,
          web: :inet.port_number() | nil,
          internal: :inet.port_number() | nil
        }

  @type status :: %{
          alive?: boolean(),
          exit_status: integer() | nil,
          os_pid: non_neg_integer() | nil,
          ip: :inet.ip_address(),
          ports: ports(),
          binary: Path.t()
        }

  @typedoc """
  Why the relay did not start: no binary, no listener asked for, it exited
  (with its first output lines), or it did not accept connections in time.
  """
  @type start_error ::
          :no_binary
          | :no_listener
          | {:exited, integer() | term(), [String.t()]}
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
  The version the binary reports, e.g. `"0.15.8"`.
  """
  @spec version(Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def version(binary \\ find_binary()) do
    with path when is_binary(path) <- binary || {:error, :no_binary},
         {out, 0} <- System.cmd(path, ["--help"], stderr_to_stdout: true),
         [line | _rest] <- String.split(out, "\n"),
         ["moq-relay", version] <- String.split(String.trim(line), " ", parts: 2) do
      {:ok, version}
    else
      {:error, _reason} = error -> error
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
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    listen = fn
      _flag, nil -> []
      flag, port -> [flag, address(ip, port)]
    end

    auth =
      case Keyword.get(opts, :auth_public, "**") do
        list when is_list(list) -> Enum.join(list, ",")
        string -> string
      end

    tls =
      case {Keyword.get(opts, :quic), Keyword.get(opts, :tls_generate, "localhost")} do
        {nil, _host} -> []
        {_quic, nil} -> []
        {_quic, host} -> ["--listen-tls-generate", host]
      end

    ["--log-level", Keyword.get(opts, :log_level, "warn")] ++
      listen.("--listen", Keyword.get(opts, :quic)) ++
      listen.("--listen-tcp-bind", Keyword.get(opts, :tcp)) ++
      listen.("--web-http-listen", Keyword.get(opts, :web)) ++
      listen.("--internal-listen", Keyword.get(opts, :internal)) ++
      tls ++
      ["--auth-public", auth] ++
      Keyword.get(opts, :args, [])
  end

  @spec status(GenServer.server()) :: status()
  def status(relay), do: GenServer.call(relay, :status)

  @spec ports(GenServer.server()) :: ports()
  def ports(relay), do: status(relay).ports

  @doc "`https://host:port` of the QUIC listener, or `nil`; append the path yourself."
  @spec quic_url(GenServer.server()) :: String.t() | nil
  def quic_url(relay), do: url(relay, "https", :quic)

  @doc "`tcp://host:port` of the plaintext TCP listener, or `nil`."
  @spec tcp_url(GenServer.server()) :: String.t() | nil
  def tcp_url(relay), do: url(relay, "tcp", :tcp)

  @doc """
  `http://host:port` of the web listener (`/health`, `/certificate.sha256`,
  `/fetch`), or `nil`.
  """
  @spec web_url(GenServer.server()) :: String.t() | nil
  def web_url(relay), do: url(relay, "http", :web)

  @doc "`http://host:port` of the internal listener (`/health`, `/metrics`), or `nil`."
  @spec internal_url(GenServer.server()) :: String.t() | nil
  def internal_url(relay), do: url(relay, "http", :internal)

  @doc """
  The OS pid of the relay process itself (not the muontrap wrapper), or `nil`
  while it has not been spawned yet or after it exited before this was first
  asked.
  """
  @spec os_pid(GenServer.server()) :: non_neg_integer() | nil
  def os_pid(relay), do: status(relay).os_pid

  @doc "Stops the relay and this process."
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(relay, timeout \\ 5_000), do: GenServer.stop(relay, :normal, timeout)

  ## GenServer

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    with binary when is_binary(binary) <- find_binary(opts) || :no_binary,
         ports = %{
           quic: resolve_port(Keyword.get(opts, :quic, :auto), :udp, ip),
           tcp: resolve_port(Keyword.get(opts, :tcp), :tcp, ip),
           web: resolve_port(Keyword.get(opts, :web), :tcp, ip),
           internal: resolve_port(Keyword.get(opts, :internal, :auto), :tcp, ip)
         },
         true <- (ports.quic != nil or ports.tcp != nil) || :no_listener do
      me = self()

      daemon_opts = [
        stderr_to_stdout: true,
        logger_fun: fn line -> send(me, {:moq_relay_output, line}) end,
        exit_status_to_reason: &{:exit_status, &1}
      ]

      args = args(Keyword.merge(opts, Map.to_list(ports)))
      Process.flag(:trap_exit, true)
      {:ok, daemon} = MuonTrap.Daemon.start_link(binary, args, daemon_opts)

      state = %{
        binary: binary,
        daemon: daemon,
        ip: ip,
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
          :none -> nil
          listener when listener in [:internal, :web, :tcp] -> ports[listener]
        end

      timeout = Keyword.get(opts, :ready_timeout, @default_ready_timeout_ms)

      case await_ready(state, ready_port, System.monotonic_time(:millisecond) + timeout, timeout) do
        {:ok, state} ->
          {:ok, state}

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
    alive? = state.exit_status == nil and Process.alive?(state.daemon)

    # Looked up on demand: the relay may not have been spawned yet when
    # start_link/1 returned (with `ready: :none`, or a probe answered early).
    state =
      if state.os_pid == nil and alive?,
        do: %{state | os_pid: relay_os_pid(state.daemon)},
        else: state

    {:reply,
     %{
       alive?: alive?,
       exit_status: state.exit_status,
       os_pid: state.os_pid,
       ip: state.ip,
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
        _other -> -1
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

  defp default_ready(ports), do: Enum.find([:internal, :web, :tcp], :none, &(ports[&1] != nil))

  defp await_ready(state, nil, _deadline, _timeout), do: {:ok, state}

  # Output and the daemon's exit are handled here too, since init/1 cannot
  # rely on handle_info/2 yet.
  defp await_ready(state, port, deadline, timeout) do
    receive do
      {:moq_relay_output, line} ->
        await_ready(output(state, line), port, deadline, timeout)

      {:EXIT, daemon, reason} when daemon == state.daemon ->
        status = with {:exit_status, s} <- reason, do: s
        {:error, {:exited, status, head(state)}, %{state | exit_status: -1}}
    after
      @probe_interval_ms ->
        cond do
          probe(state.ip, port) ->
            {:ok, state}

          System.monotonic_time(:millisecond) > deadline ->
            {:error, {:not_ready, timeout, head(state)}, state}

          true ->
            await_ready(state, port, deadline, timeout)
        end
    end
  end

  defp probe(ip, port) do
    host = reachable(ip)

    case :gen_tcp.connect(host, port, [:binary, active: false] ++ family(host), 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
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

  ## Addresses, ports and pids

  defp resolve_port(nil, _kind, _ip), do: nil
  defp resolve_port(port, _kind, _ip) when is_integer(port), do: port

  defp resolve_port(:auto, :udp, ip) do
    {:ok, socket} = :gen_udp.open(0, [ip: ip] ++ family(ip))
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  defp resolve_port(:auto, :tcp, ip) do
    {:ok, socket} = :gen_tcp.listen(0, [ip: ip] ++ family(ip))
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp family(ip) when tuple_size(ip) == 8, do: [:inet6]
  defp family(_ip), do: []

  # Where a listener bound to `ip` is reached from this host.
  defp reachable({0, 0, 0, 0}), do: {127, 0, 0, 1}
  defp reachable({0, 0, 0, 0, 0, 0, 0, 0}), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp reachable(ip), do: ip

  defp address(ip, port) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]:#{port}"
  defp address(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  defp url(relay, scheme, listener) do
    %{ip: ip, ports: ports} = status(relay)

    case ports[listener] do
      nil -> nil
      port -> "#{scheme}://#{address(reachable(ip), port)}"
    end
  end

  # `MuonTrap.Daemon.os_pid/1` is the muontrap wrapper; the relay is its child.
  defp relay_os_pid(daemon) do
    with wrapper when is_integer(wrapper) <- MuonTrap.Daemon.os_pid(daemon),
         {out, 0} <-
           System.cmd("pgrep", ["-P", Integer.to_string(wrapper)], stderr_to_stdout: true),
         {child, _rest} <-
           out |> String.trim() |> String.split("\n") |> List.first() |> Integer.parse() do
      child
    else
      _other -> nil
    end
  end
end
