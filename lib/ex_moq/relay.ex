defmodule ExMoQ.Relay do
  @moduledoc """
  Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
  process.

  The struct holds the options of a relay to start:

      {:ok, relay} = ExMoQ.Relay.start_link(%ExMoQ.Relay{tcp: :auto})
      ExMoQ.Relay.info(relay).tcp_url  #=> "tcp://127.0.0.1:54321"

  The process returned by `start_link/1` owns the relay: the relay stops with
  it, and it exits with `{:exit_status, status}` when the relay exits with a
  non-zero status. Under a supervisor, the `:restart` setting decides what
  happens then:

      {ExMoQ.Relay, %ExMoQ.Relay{quic: 4443, web: 4443, name: MyApp.Relay}}

  Starting returns once the relay's listeners are bound and it accepts
  sessions. The ports it picked for `:auto` are in `info/1`.

  ## Options

    * `:binary` - path to the relay; see `find_binary/1` for the default.
    * `:ip` - the address the listeners bind to (default `{127, 0, 0, 1}`).
    * `:quic` - the QUIC listener: `:auto` (default), a port, or `nil`. Its
      certificate is generated for `"localhost"`; `{port, tls_generate: host}`
      names another host, and `{port, tls_generate: nil}` generates none, for
      one passed in `:args`.
    * `:tcp` - a plaintext TCP listener: `:auto`, a port, or `nil` (default).
    * `:web` - the HTTP listener serving `/health`, `/certificate.sha256`,
      `/fetch` and WebSocket: `:auto`, a port, or `nil` (default). It may
      share its port number with `:quic`.
    * `:internal` - the HTTP listener serving `/health`, `/metrics` and
      `/sessions`: a port or `nil` (default). It cannot be `:auto`.
    * `:auth_public` - path patterns anonymous sessions may publish and
      subscribe to, a string or a list (default `"**"`, everything); `nil`
      for none.
    * `:log_level` - the relay's log level: `"error"`, `"warn"` (default),
      `"info"`, `"debug"` or `"trace"`.
    * `:args` - extra command-line arguments.
    * `:output` - where the relay's output lines go: a `Logger` level to log
      them at (default `:info`), a 1-arity function to call with each, or
      `nil` to drop them.
    * `:ready_timeout` - milliseconds to wait for readiness (default 15 000).
    * `:name` - a name to register the relay's process under (default `nil`).
  """

  use GenServer

  require Logger

  alias ExMoQ.Relay.Info

  @log_levels ["error", "warn", "info", "debug", "trace"]
  @listening_targets ["moq_relay::relay", "moq_relay::web", "moq_tokio::server"]

  @typedoc "A listener port: `:auto` until the relay binds it."
  @type port_option :: :auto | :inet.port_number() | nil

  @typedoc "The QUIC listener, see `:quic`."
  @type quic_option :: port_option() | {:auto | :inet.port_number(), quic_listener_opts()}

  @typedoc "Options of the QUIC listener, for `{port, opts}` in `:quic`."
  @type quic_listener_opts :: [{:tls_generate, String.t() | nil}]

  @typedoc "Where the relay's output lines go."
  @type output :: Logger.level() | (String.t() -> any()) | nil

  @type t :: %__MODULE__{
          binary: Path.t() | nil,
          ip: :inet.ip_address(),
          quic: quic_option(),
          tcp: port_option(),
          web: port_option(),
          internal: :inet.port_number() | nil,
          auth_public: String.t() | [String.t()] | nil,
          log_level: String.t(),
          args: [String.t()],
          output: output(),
          ready_timeout: non_neg_integer(),
          name: GenServer.name() | nil
        }

  defstruct binary: nil,
            ip: {127, 0, 0, 1},
            quic: :auto,
            tcp: nil,
            web: nil,
            internal: nil,
            auth_public: "**",
            log_level: "warn",
            args: [],
            output: :info,
            ready_timeout: 15_000,
            name: nil

  @typedoc """
  Why the relay did not start: it exited with the given status, or it did
  not report readiness within the given milliseconds.
  """
  @type start_error ::
          {:exit_status, non_neg_integer()}
          | {:not_ready, timeout_ms :: non_neg_integer()}

  @typedoc "Why `version/1` could not read the relay's version."
  @type version_error ::
          :no_binary
          | {:exit_status, integer(), output :: String.t()}
          | {:unexpected_output, term()}

  @doc """
  A child spec for the relay. Relays can share a supervisor without explicit
  ids. Raises like `start_link/1`, in the caller rather than the supervisor.
  """
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{} = options) do
    %{
      id: {__MODULE__, options.name || make_ref()},
      start: {__MODULE__, :start_link, [validate!(options)]},
      type: :worker
    }
  end

  @doc """
  Starts a relay linked to the caller and blocks until it is ready.

  Raises `ArgumentError` when the relay binary is not found or the options
  are ones the relay cannot run with.

  A relay that exits with a non-zero status before it is ready exits the
  caller with `{:exit_status, status}` unless the caller traps exits, as
  with `GenServer.start_link/3`; `start/1` returns that error instead.
  """
  @spec start_link(t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start_link(%__MODULE__{} = options),
    do: GenServer.start_link(__MODULE__, validate!(options), name: options.name)

  @doc "Starts a relay not linked to the caller; see `start_link/1`."
  @spec start(t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start(%__MODULE__{} = options),
    do: GenServer.start(__MODULE__, validate!(options), name: options.name)

  @doc "What the relay reports: where its listeners are reached."
  @spec info(GenServer.server()) :: Info.t()
  def info(relay), do: GenServer.call(relay, :info)

  @doc "Stops the relay."
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(relay, timeout \\ 5_000), do: GenServer.stop(relay, :normal, timeout)

  @doc """
  Finds the relay binary: `binary` if given, else `$MOQ_RELAY`, else
  `moq-relay` on `$PATH`. Returns `nil` when that is not an executable.
  """
  @spec find_binary(Path.t() | nil) :: Path.t() | nil
  def find_binary(binary \\ nil) do
    System.find_executable(binary || System.get_env("MOQ_RELAY") || "moq-relay")
  end

  @doc "The relay binary's version, e.g. `\"0.15.8\"`."
  @spec version(Path.t() | nil) :: {:ok, String.t()} | {:error, version_error()}
  def version(binary \\ find_binary()) do
    with path when is_binary(path) <- binary || {:error, :no_binary},
         {out, 0} <- System.cmd(path, ["--version"], stderr_to_stdout: true),
         ["moq-relay", version] <- out |> String.trim() |> String.split(" ", parts: 2) do
      {:ok, version}
    else
      {:error, _reason} = error -> error
      {out, status} when is_integer(status) -> {:error, {:exit_status, status, out}}
      other -> {:error, {:unexpected_output, other}}
    end
  end

  @doc """
  The arguments the relay binary is run with; `:auto` ports are port 0.
  Raises like `start_link/1`.
  """
  @spec args(t()) :: [String.t()]
  def args(%__MODULE__{} = options) do
    options = validate!(options)

    listen = fn
      _flag, nil -> []
      flag, :auto -> [flag, address(options.ip, 0)]
      flag, port -> [flag, address(options.ip, port)]
    end

    auth =
      case options.auth_public do
        nil -> []
        list when is_list(list) -> ["--auth-public", Enum.join(list, ",")]
        string -> ["--auth-public", string]
      end

    tls =
      case options.quic do
        {_port, tls_generate: host} when host != nil -> ["--listen-tls-generate", host]
        _no_certificate -> []
      end

    ["--log-level", options.log_level] ++
      listen.("--listen", quic_port(options)) ++
      listen.("--listen-tcp-bind", options.tcp) ++
      listen.("--web-http-listen", options.web) ++
      listen.("--internal-listen", options.internal) ++
      tls ++
      auth ++
      options.args
  end

  @doc false
  @spec quic_port(t()) :: port_option()
  def quic_port(%__MODULE__{quic: {port, _tls}}), do: port
  def quic_port(%__MODULE__{quic: nil}), do: nil

  @doc false
  @spec address(:inet.ip_address(), :inet.port_number()) :: String.t()
  def address(ip, port) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]:#{port}"
  def address(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  ## Server

  @impl true
  def init(%__MODULE__{} = options) do
    deadline = System.monotonic_time(:millisecond) + options.ready_timeout
    path = notify_path()
    File.rm(path)
    {:ok, notify} = :gen_udp.open(0, [:local, :binary, active: true, ifaddr: {:local, path}])

    daemon_opts = [
      stderr_to_stdout: true,
      exit_status_to_reason: &{:exit_status, &1},
      logger_fun: logger_fun(options, self()),
      env: env(options, path)
    ]

    {:ok, daemon} = MuonTrap.Daemon.start_link(options.binary, args(options), daemon_opts)
    state = %{options: options, daemon: daemon, monitor: Process.monitor(daemon)}
    result = await_ready(state, notify, false, deadline)
    :ok = :gen_udp.close(notify)
    File.rm(path)

    case result do
      {:ok, %{options: options} = state} ->
        {:ok, %{daemon: state.daemon, monitor: state.monitor, info: Info.new(options)}}

      {:error, {:not_ready, _timeout_ms}} = error ->
        stop_daemon(daemon)
        error

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  @impl true
  def handle_info({:listening, _listener, _port}, state), do: {:noreply, state}

  # The link takes the relay down when the daemon exits abnormally; this
  # covers a relay that exits with status 0, whose `:normal` exit the link
  # ignores.
  def handle_info({:DOWN, monitor, :process, _daemon, reason}, %{monitor: monitor} = state),
    do: {:stop, reason, %{state | daemon: nil}}

  @impl true
  def terminate(_reason, %{daemon: nil}), do: :ok
  def terminate(_reason, %{daemon: daemon}), do: stop_daemon(daemon)

  ## Validating

  @spec validate!(t()) :: t()
  defp validate!(%__MODULE__{} = options) do
    binary = binary!(options.binary)
    output!(options.output)
    log_level!(options.log_level)
    quic = quic!(options.quic)
    Enum.each([:tcp, :web], &port!(&1, Map.fetch!(options, &1)))
    internal!(options.internal)

    if quic == nil and options.tcp == nil,
      do: raise(ArgumentError, "a relay needs a :quic or a :tcp listener, both are nil")

    %__MODULE__{options | binary: binary, quic: quic}
  end

  @spec binary!(Path.t() | nil) :: Path.t()
  defp binary!(binary) do
    find_binary(binary) ||
      raise ArgumentError, "no moq-relay binary found; see ExMoQ.Relay.find_binary/1"
  end

  @spec output!(term()) :: :ok
  defp output!(output) when output == nil or is_function(output, 1), do: :ok

  defp output!(level) do
    if level not in Logger.levels(),
      do:
        raise(
          ArgumentError,
          ":output must be a Logger level, a 1-arity function or nil, got: #{inspect(level)}"
        )

    :ok
  end

  @spec log_level!(term()) :: :ok
  defp log_level!(level) when level in @log_levels, do: :ok

  defp log_level!(other),
    do:
      raise(
        ArgumentError,
        ":log_level must be one of #{inspect(@log_levels)}, got: #{inspect(other)}"
      )

  @spec quic!(term()) :: {:auto | :inet.port_number(), quic_listener_opts()} | nil
  defp quic!(nil), do: nil

  defp quic!({port, opts}) when is_list(opts) do
    if port == nil, do: raise(ArgumentError, "a :quic listener needs a port or :auto, got: nil")
    port!(:quic, port)
    {port, Keyword.validate!(opts, tls_generate: "localhost")}
  end

  defp quic!(port), do: quic!({port, []})

  @spec internal!(term()) :: :ok
  defp internal!(:auto),
    do:
      raise(
        ArgumentError,
        ":internal must be a port or nil: the relay does not report the port it binds for :auto"
      )

  defp internal!(port), do: port!(:internal, port)

  @spec port!(atom(), term()) :: :ok
  defp port!(_key, value) when value in [nil, :auto], do: :ok
  defp port!(_key, port) when port in 1..65_535, do: :ok

  defp port!(key, other),
    do:
      raise(ArgumentError, "#{inspect(key)} must be :auto, a port or nil, got: #{inspect(other)}")

  ## Starting

  @spec notify_path() :: Path.t()
  defp notify_path() do
    name = "moq-relay-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    Path.join(System.tmp_dir!(), name)
  end

  # `RUST_LOG` overrides `--log-level`, so it can lift just the targets that
  # log the bound addresses to info; the lines below the asked-for level are
  # then dropped in `logger_fun/2`.
  @spec env(t(), Path.t()) :: [{String.t(), String.t()}]
  defp env(options, notify_path) do
    rust_log =
      if raise_level?(options) do
        directives = Enum.map(@listening_targets, &"#{&1}=info")
        [{"RUST_LOG", Enum.join([options.log_level | directives], ",")}]
      else
        []
      end

    [{"NOTIFY_SOCKET", notify_path}, {"NO_COLOR", "1"}] ++ rust_log
  end

  @spec raise_level?(t()) :: boolean()
  defp raise_level?(options),
    do: not resolved?(options) and level_index(options.log_level) < level_index("info")

  @spec await_ready(map(), :gen_udp.socket(), boolean(), integer()) ::
          {:ok, map()} | {:error, start_error() | term()}
  defp await_ready(state, notify, notified?, deadline) do
    if notified? and resolved?(state.options) do
      {:ok, state}
    else
      monitor = state.monitor
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:udp, ^notify, _address, _port, message} ->
          ready? = "READY=1" in String.split(message, "\n")
          await_ready(state, notify, notified? or ready?, deadline)

        {:listening, listener, port} ->
          options = resolve(state.options, listener, port)
          await_ready(%{state | options: options}, notify, notified?, deadline)

        {:DOWN, ^monitor, :process, _daemon, :normal} ->
          {:error, {:exit_status, 0}}

        {:DOWN, ^monitor, :process, _daemon, reason} ->
          {:error, reason}
      after
        timeout -> {:error, {:not_ready, state.options.ready_timeout}}
      end
    end
  end

  @spec resolved?(t()) :: boolean()
  defp resolved?(options), do: :auto not in [quic_port(options), options.tcp, options.web]

  @spec resolve(t(), :quic | :tcp | :web, :inet.port_number()) :: t()
  defp resolve(options, listener, port) do
    case {listener, options} do
      {:quic, %__MODULE__{quic: {:auto, tls}}} -> %__MODULE__{options | quic: {port, tls}}
      {:tcp, %__MODULE__{tcp: :auto}} -> %__MODULE__{options | tcp: port}
      {:web, %__MODULE__{web: :auto}} -> %__MODULE__{options | web: port}
      _other -> options
    end
  end

  # Runs in the daemon's process, so the lines a relay prints as it exits are
  # written out before the exit reaches the relay's process.
  @spec logger_fun(t(), pid()) :: (String.t() -> :ok)
  defp logger_fun(options, server) do
    filter_level? = raise_level?(options)
    resolve? = not resolved?(options)

    fn line ->
      if not filter_level? or within_level?(line, options.log_level), do: output(options, line)

      with true <- resolve?,
           {listener, port} <- listening(line),
           do: send(server, {:listening, listener, port})

      :ok
    end
  end

  @spec listening(String.t()) :: {:quic | :tcp | :web, :inet.port_number()} | nil
  defp listening(line) do
    patterns = [
      quic: ~r/ listening addr=\S+:(\d+) kind="quic"/,
      web: ~r/ listening addr=\S+:(\d+) kind="http"/,
      tcp: ~r/ listening \(tcp\) addr=\S+:(\d+)/
    ]

    Enum.find_value(patterns, fn {listener, pattern} ->
      with [port] <- Regex.run(pattern, line, capture: :all_but_first),
           do: {listener, String.to_integer(port)}
    end)
  end

  @spec output(t(), String.t()) :: :ok
  defp output(options, line) do
    case options.output do
      nil -> :ok
      fun when is_function(fun, 1) -> fun.(line)
      level -> Logger.log(level, "moq-relay: " <> line)
    end

    :ok
  end

  # Lines without a level, like the ones of an error the relay exits with,
  # are always within it.
  @spec within_level?(String.t(), String.t()) :: boolean()
  defp within_level?(line, log_level) do
    case Regex.run(~r/^\S+\s+(ERROR|WARN|INFO|DEBUG|TRACE) /, line, capture: :all_but_first) do
      [level] -> level_index(String.downcase(level)) <= level_index(log_level)
      nil -> true
    end
  end

  @spec level_index(String.t()) :: non_neg_integer()
  defp level_index(level), do: Enum.find_index(@log_levels, &(&1 == level))

  @spec stop_daemon(pid()) :: :ok
  defp stop_daemon(daemon) do
    GenServer.stop(daemon)
  catch
    :exit, _reason -> :ok
  end
end
