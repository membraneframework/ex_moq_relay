defmodule ExMoQ.Relay do
  @moduledoc """
  Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
  process.

  The struct holds the options of a relay to start (see
  [`%ExMoQ.Relay{}`](`__struct__/0`)):

      {:ok, relay} = ExMoQ.Relay.start_link(%ExMoQ.Relay{quic: 4443})
      ExMoQ.Relay.info(relay).quic  #=> {"https://127.0.0.1:4443", :generated}

  The relay stops with the process `start_link/1` returns, and that process
  exits with `{:exit_status, status}` when the relay exits on its own. Under
  a supervisor:

      {ExMoQ.Relay, %ExMoQ.Relay{quic: 4443, web: 4443, name: MyApp.Relay}}
  """

  use GenServer

  alias ExMoQ.Relay.{Args, Info, Options, Startup}

  @doc """
  The options of a relay to start.
    * `:binary` - path to the relay; when `nil` (default), see `find_binary/1`.
    * `:ip` - address the listeners bind to (default `{127, 0, 0, 1}`). A
      listener binds to one of its own as `{port, ip: ip}`, like
      `web: {8080, ip: {127, 0, 0, 1}}` next to a public `:quic`.
    * `:quic` - the QUIC listener (default `4443`). Its certificate is
      generated for `"localhost"`; `{port, tls_generate: host}` names another
      host, and `{port, tls_generate: nil}` generates none, for one passed in
      `:args`.
    * `:tcp` - a plaintext TCP listener (default `nil`).
    * `:web` - the HTTP listener serving `moq-relay`
      [endpoints](https://doc.moq.dev/bin/relay/http.html) (default `nil`).
      It may share its port number with `:quic`.
    * `:internal` - the HTTP listener for operators (default `nil`).
    * `:auth` - see `t:auth/0`.
    * `:log_level` - the relay's log level (default `:warning`).
    * `:args` - extra command-line arguments (default `[]`).
    * `:output` - where the relay's output lines go (default `:info`), see
      `t:output/0`.
    * `:ready_timeout` - milliseconds to wait for readiness (default `15_000`).
    * `:name` - a name to register the relay's process under (default `nil`).
  """
  defstruct binary: nil,
            ip: {127, 0, 0, 1},
            quic: 4443,
            tcp: nil,
            web: nil,
            internal: nil,
            auth: "**",
            log_level: :warning,
            args: [],
            output: :info,
            ready_timeout: 15_000,
            name: nil

  @typedoc """
  Options of a relay to start.

  See [`%ExMoQ.Relay{}`](`__struct__/0`) for information about each field.
  """
  @type t :: %__MODULE__{
          binary: Path.t() | nil,
          ip: :inet.ip_address(),
          quic: quic_listener(),
          tcp: listener(),
          web: listener(),
          internal: listener(),
          auth: auth(),
          log_level: Logger.level(),
          args: [String.t()],
          output: output(),
          ready_timeout: non_neg_integer(),
          name: GenServer.name() | nil
        }

  @typedoc "A listener: a port, `{port, opts}`, or `nil` for none."
  @type listener :: :inet.port_number() | {:inet.port_number(), [{:ip, :inet.ip_address()}]} | nil

  @typedoc "The QUIC listener: a `t:listener/0` that also takes `:tls_generate`."
  @type quic_listener ::
          :inet.port_number()
          | {:inet.port_number(), [{:ip, :inet.ip_address()} | {:tls_generate, String.t() | nil}]}
          | nil

  @typedoc """
  How sessions are admitted.

  * Path patterns for anonymous access (`"**"` is everything)
  * `[subscribe: patterns, publish: patterns]` to grant the two
  apart (`[subscribe: "**"]` lets anyone subscribe and no one publish)
  * `{:url, url}` for an auth server the relay POSTs to (`http://`,
  `https://`, or `unix://`, see [Authentication](https://doc.moq.dev/bin/relay/auth))
  * `nil` for none, leaving auth to `:args`
  """
  @type auth ::
          patterns()
          | [{:subscribe, patterns()} | {:publish, patterns()}, ...]
          | {:url, String.t()}
          | nil

  @typedoc "Path patterns: one, or a list."
  @type patterns :: String.t() | [String.t(), ...]

  @typedoc """
  Where the relay's output lines go: a `Logger` level to log them at, a
  1-arity function to call with each, or `nil` to drop them.
  """
  @type output :: Logger.level() | (String.t() -> any()) | nil

  @typedoc "Why the relay did not start."
  @type start_error ::
          {:validation_failed, String.t()}
          | {:binary_not_found, name :: Path.t()}
          | {:exit_status, non_neg_integer()}
          | {:not_ready, timeout_ms :: non_neg_integer()}

  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{} = relay) do
    %{
      id: {__MODULE__, relay.name || make_ref()},
      start: {__MODULE__, :start_link, [relay]},
      type: :worker
    }
  end

  @doc """
  Starts a relay linked to the caller and blocks until moq-relay is ready to accept connections.
  """
  @spec start_link(t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start_link(%__MODULE__{} = relay) do
    with {:ok, {_binary, options} = validated} <- validate(relay) do
      GenServer.start_link(__MODULE__, validated, name: options.name)
    end
  end

  @doc "Starts a relay not linked to the caller and blocks until moq-relay is ready to accept connections."
  @spec start(t()) :: {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start(%__MODULE__{} = relay) do
    with {:ok, {_binary, options} = validated} <- validate(relay) do
      GenServer.start(__MODULE__, validated, name: options.name)
    end
  end

  @spec validate(t()) ::
          {:ok, {Path.t(), Options.t()}}
          | {:error, {:validation_failed, String.t()} | {:binary_not_found, Path.t()}}
  defp validate(%__MODULE__{} = relay) do
    with {:ok, options} <- Options.validate(relay),
         {:ok, binary} <- resolve_binary(relay.binary) do
      {:ok, {binary, options}}
    else
      {:error, message} when is_binary(message) -> {:error, {:validation_failed, message}}
      {:error, _reason} = error -> error
    end
  end

  @spec resolve_binary(Path.t() | nil) ::
          {:ok, Path.t()} | {:error, {:binary_not_found, Path.t()}}
  defp resolve_binary(binary) do
    name = binary_name(binary)

    case System.find_executable(name) do
      nil -> {:error, {:binary_not_found, name}}
      path -> {:ok, path}
    end
  end

  @doc """
  Endpoints through which the relay can be reached, see
  [`%ExMoQ.Relay.Info{}`](`ExMoQ.Relay.Info.__struct__/0`).
  """
  @spec info(GenServer.server()) :: Info.t()
  def info(relay), do: GenServer.call(relay, :info)

  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(relay, timeout \\ 5_000), do: GenServer.stop(relay, :normal, timeout)

  @doc """
  Finds the relay binary:
  * `binary` if given,
  * else `$MOQ_RELAY`,
  * else looks it up on `$PATH`.

  A path is expanded relative to the current directory. Returns `nil` if not found.
  """
  @spec find_binary(Path.t() | nil) :: Path.t() | nil
  def find_binary(binary \\ nil), do: System.find_executable(binary_name(binary))

  @spec binary_name(Path.t() | nil) :: Path.t()
  defp binary_name(binary) do
    name = binary || System.get_env("MOQ_RELAY") || "moq-relay"
    if String.contains?(name, "/"), do: Path.expand(name), else: name
  end

  @doc """
  The arguments the relay binary is run with.
  Raises `ArgumentError` when options fail validation.
  """
  @spec args(t()) :: [String.t()]
  def args(%__MODULE__{} = relay), do: relay |> Options.validate!() |> Args.args()

  ## Server

  @impl true
  def init({binary, %Options{} = options}) do
    case Startup.run(binary, options) do
      {:ok, %{daemon: daemon, monitor: monitor}} ->
        {:ok, %{daemon: daemon, monitor: monitor, info: Info.new(options)}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  # Need to map exit_status = 0 explicitly
  @impl true
  def handle_info({:DOWN, monitor, :process, _daemon, :normal}, %{monitor: monitor} = state),
    do: {:stop, {:exit_status, 0}, %{state | daemon: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: nil}), do: :ok

  def terminate(_reason, %{daemon: daemon}) do
    GenServer.stop(daemon)
  catch
    :exit, _reason -> :ok
  end
end
