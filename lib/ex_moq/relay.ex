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
      A listener binds to one of its own as `{port, ip: ip}`, like
      `web: {:auto, ip: {127, 0, 0, 1}}` next to a public `:quic`.
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
    * `:auth` - how sessions are admitted (default `"**"`, everything):
      path patterns (a string or a list) for anonymous access;
      `[subscribe: patterns, publish: patterns]` to grant the two apart
      (`[subscribe: "**"]` lets anyone subscribe and no one publish);
      `{:url, url}` for an auth server the relay POSTs to (`http://`,
      `https://`, or `unix://`, see [Authentication](https://doc.moq.dev/bin/relay/auth));
      or `nil` for none, leaving auth to `:args`.
    * `:log_level` - the relay's log level: `"error"`, `"warn"` (default),
      `"info"`, `"debug"` or `"trace"`. It replaces a `RUST_LOG` of the
      environment, which the relay does not inherit.
    * `:args` - extra command-line arguments.
    * `:output` - where the relay's output lines go: a `Logger` level to log
      them at (default `:info`), a 1-arity function to call with each, or
      `nil` to drop them.
    * `:ready_timeout` - milliseconds to wait for readiness (default 15 000).
    * `:name` - a name to register the relay's process under (default `nil`).
  """

  use GenServer

  require Logger

  alias ExMoQ.Relay.{Args, Info, Options}

  @listening_targets ["moq_relay::relay", "moq_relay::web", "moq_tokio::server"]

  @typedoc "Path patterns, like `\"anon/**\"`: one, or a list."
  @type patterns :: String.t() | [String.t()]

  @typedoc "How sessions are admitted, see `:auth`."
  @type auth ::
          patterns()
          | [subscribe: patterns(), publish: patterns()]
          | {:url, String.t()}
          | nil

  @typedoc "A listener port: `:auto` until the relay binds it."
  @type port_option :: :auto | :inet.port_number() | nil

  @typedoc "A listener: its port, or `{port, opts}`."
  @type listener_option :: port_option() | {:auto | :inet.port_number(), listener_opts()}

  @typedoc "Options of a listener, for `{port, opts}`: the address it binds to."
  @type listener_opts :: [{:ip, :inet.ip_address()}]

  @typedoc "The QUIC listener, see `:quic`."
  @type quic_option :: port_option() | {:auto | :inet.port_number(), quic_listener_opts()}

  @typedoc "Options of the QUIC listener, for `{port, opts}` in `:quic`."
  @type quic_listener_opts :: [{:tls_generate, String.t() | nil} | {:ip, :inet.ip_address()}]

  @typedoc "Where the relay's output lines go."
  @type output :: Logger.level() | (String.t() -> any()) | nil

  @type t :: %__MODULE__{
          binary: Path.t() | nil,
          ip: :inet.ip_address(),
          quic: quic_option(),
          tcp: listener_option(),
          web: listener_option(),
          internal: :inet.port_number() | {:inet.port_number(), listener_opts()} | nil,
          auth: auth(),
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
            auth: "**",
            log_level: "warn",
            args: [],
            output: :info,
            ready_timeout: 15_000,
            name: nil

  @typedoc """
  Why the relay did not start: options failed validation, it exited with the
  given status, or it did not report readiness within the given milliseconds.
  """
  @type start_error ::
          {:validation_failed, String.t()}
          | {:exit_status, non_neg_integer()}
          | {:not_ready, timeout_ms :: non_neg_integer()}

  @doc """
  A child spec for the relay. Raises `ArgumentError` when options fail validation.
  """
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{} = relay) do
    options = Options.validate!(relay)

    %{
      id: {__MODULE__, options.name || make_ref()},
      start: {__MODULE__, :start_link, [options]},
      type: :worker
    }
  end

  @doc """
  Starts a relay linked to the caller and blocks until it is ready.
  """
  @spec start_link(t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start_link(%__MODULE__{} = relay) do
    case Options.validate(relay) do
      {:ok, options} -> start_link(options)
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  @doc false
  @spec start_link(Options.t()) ::
          {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start_link(%Options{} = options),
    do: GenServer.start_link(__MODULE__, options, name: options.name)

  @doc "Starts a relay not linked to the caller; see `start_link/1`."
  @spec start(t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start(%__MODULE__{} = relay) do
    case Options.validate(relay) do
      {:ok, options} -> start(options)
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  @doc false
  @spec start(Options.t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start(%Options{} = options),
    do: GenServer.start(__MODULE__, options, name: options.name)

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

  @doc """
  The relay binary's version, e.g. `"0.15.8"`.
  """
  @spec version(Path.t() | nil) ::
          {:ok, String.t()}
          | {:error,
             :no_binary
             | {:exit_status, integer(), output :: String.t()}
             | {:unexpected_output, term()}}
  def version(binary \\ nil) do
    with path when is_binary(path) <- find_binary(binary) || {:error, :no_binary},
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
  Raises `ArgumentError` when options fail validation.
  """
  @spec args(t()) :: [String.t()]
  def args(%__MODULE__{} = relay), do: relay |> Options.validate!() |> Args.args()

  ## Server

  @impl true
  def init(%Options{} = options) do
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

    {:ok, daemon} = MuonTrap.Daemon.start_link(options.binary, Args.args(options), daemon_opts)
    state = %{options: options, daemon: daemon, monitor: Process.monitor(daemon)}
    result = await_ready(state, notify, false, deadline)
    :ok = :gen_udp.close(notify)
    File.rm(path)

    case result do
      {:ok, %{options: options} = state} ->
        {:ok, %{daemon: state.daemon, monitor: state.monitor, info: Info.new(options)}}

      {:error, {:not_ready, _timeout_ms} = reason} ->
        stop_daemon(daemon)
        {:stop, reason}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _daemon, reason}, %{monitor: monitor} = state),
    do: {:stop, reason, %{state | daemon: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: nil}), do: :ok
  def terminate(_reason, %{daemon: daemon}), do: stop_daemon(daemon)

  ## Starting

  @spec notify_path() :: Path.t()
  defp notify_path() do
    name = "moq-relay-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    Path.join(System.tmp_dir!(), name)
  end

  @spec env(Options.t(), Path.t()) :: [{String.t(), String.t()}]
  defp env(options, notify_path) do
    directives =
      if raise_level?(options), do: Enum.map(@listening_targets, &"#{&1}=info"), else: []

    [
      {"NOTIFY_SOCKET", notify_path},
      {"NO_COLOR", "1"},
      {"RUST_LOG", Enum.join([options.log_level | directives], ",")}
    ]
  end

  @spec raise_level?(Options.t()) :: boolean()
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

  @spec resolved?(Options.t()) :: boolean()
  defp resolved?(options),
    do: not Enum.any?([:quic, :tcp, :web], &match?({:auto, _ip}, Args.listener(options, &1)))

  @spec resolve(Options.t(), :quic | :tcp | :web, :inet.port_number()) :: Options.t()
  defp resolve(options, listener, port) do
    case Map.fetch!(options, listener) do
      :auto -> Map.replace!(options, listener, port)
      {:auto, opts} -> Map.replace!(options, listener, {port, opts})
      _other -> options
    end
  end

  # Runs in the daemon's process, so the lines a relay prints as it exits are
  # written out before the exit reaches the relay's process.
  @spec logger_fun(Options.t(), pid()) :: (String.t() -> :ok)
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

  @spec output(Options.t(), String.t()) :: :ok
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
  defp level_index(level), do: Enum.find_index(Options.log_levels(), &(&1 == level))

  @spec stop_daemon(pid()) :: :ok
  defp stop_daemon(daemon) do
    GenServer.stop(daemon)
  catch
    :exit, _reason -> :ok
  end
end
