defmodule ExMoQ.Relay.Config do
  @moduledoc """
  What `ExMoQ.Relay` runs. Build it with `new!/1`, which picks the `:auto`
  ports, so the relay's URLs are known before it starts:

      config = ExMoQ.Relay.Config.new!(tcp: :auto)
      ExMoQ.Relay.tcp_url(config)  #=> "tcp://127.0.0.1:54321"

  A port is free when `new!/1` picks it, but another process can take it
  before the relay binds it.

  ## Options

    * `:binary` - path to the relay; see `ExMoQ.Relay.find_binary/1` for
      the default.
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
      `/sessions`: `:auto` (default), a port, or `nil`.
    * `:auth_public` - path patterns anonymous sessions may publish and
      subscribe to, a string or a list (default `"**"`, everything); `nil`
      for none.
    * `:log_level` - the relay's log level (default `"warn"`).
    * `:args` - extra command-line arguments.
    * `:output` - where the relay's output lines go: a `Logger` level to log
      them at (default `:info`), a 1-arity function to call with each, or
      `nil` to drop them.
    * `:ready` - the listener `ExMoQ.Relay.start_link/1` waits for:
      `:internal`, `:web`, `:tcp` or `:none`. The default, `:auto`, is the
      first of those that is on.
    * `:ready_timeout` - milliseconds to wait for readiness (default 15 000).
    * `:name` - a name to register the relay's process under (default `nil`).
  """

  @typedoc "A listener port as given to `new!/1`."
  @type port_option :: :auto | :inet.port_number() | nil

  @typedoc "The QUIC listener as given to `new!/1`."
  @type quic_option :: port_option() | {:auto | :inet.port_number(), quic_listener_opts()}

  @typedoc "Options of the QUIC listener, for `{port, opts}` in `:quic`."
  @type quic_listener_opts :: [{:tls_generate, String.t() | nil}]

  @typedoc "Where the relay's output lines go."
  @type output :: Logger.level() | (String.t() -> any()) | nil

  @typedoc "The listeners `:ready` can probe."
  @type probed_listener :: :internal | :web | :tcp

  @type option ::
          {:binary, Path.t() | nil}
          | {:ip, :inet.ip_address()}
          | {:quic, quic_option()}
          | {:tcp | :web | :internal, port_option()}
          | {:auth_public, String.t() | [String.t()] | nil}
          | {:log_level, String.t()}
          | {:args, [String.t()]}
          | {:output, output()}
          | {:ready, :auto | probed_listener() | :none}
          | {:ready_timeout, non_neg_integer()}
          | {:name, GenServer.name() | nil}

  @type t :: %__MODULE__{
          binary: Path.t(),
          ip: :inet.ip_address(),
          quic: {:inet.port_number(), quic_listener_opts()} | nil,
          tcp: :inet.port_number() | nil,
          web: :inet.port_number() | nil,
          internal: :inet.port_number() | nil,
          auth_public: String.t() | [String.t()] | nil,
          log_level: String.t(),
          args: [String.t()],
          output: output(),
          ready: probed_listener() | :none,
          ready_timeout: non_neg_integer(),
          name: GenServer.name() | nil
        }

  defstruct binary: nil,
            ip: {127, 0, 0, 1},
            quic: :auto,
            tcp: nil,
            web: nil,
            internal: :auto,
            auth_public: "**",
            log_level: "warn",
            args: [],
            output: :info,
            ready: :auto,
            ready_timeout: 15_000,
            name: nil

  @doc """
  Builds a config from options.

  Raises `KeyError` for an unknown option and `ArgumentError` when the relay
  binary is not found or the options are ones the relay cannot run with.
  """
  @spec new!([option()]) :: t()
  def new!(opts \\ []) when is_list(opts) do
    %__MODULE__{ip: ip} = config = struct!(__MODULE__, opts)
    binary = binary!(config.binary)
    output!(config.output)
    quic = quic!(config.quic)
    Enum.each([:tcp, :web, :internal], &port!(&1, Map.fetch!(config, &1)))

    if quic == nil and config.tcp == nil,
      do: raise(ArgumentError, "a relay needs a :quic or a :tcp listener, both are nil")

    config = %__MODULE__{
      config
      | binary: binary,
        quic: with({port, tls} <- quic, do: {free_port(port, :udp, ip), tls}),
        tcp: free_port(config.tcp, :tcp, ip),
        web: free_port(config.web, :tcp, ip),
        internal: free_port(config.internal, :tcp, ip)
    }

    %__MODULE__{config | ready: ready!(config)}
  end

  @spec binary!(Path.t() | nil) :: Path.t()
  defp binary!(binary) do
    ExMoQ.Relay.find_binary(binary) ||
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

  @spec quic!(term()) :: {:auto | :inet.port_number(), quic_listener_opts()} | nil
  defp quic!(nil), do: nil

  defp quic!({port, opts}) when is_list(opts) do
    if port == nil, do: raise(ArgumentError, "a :quic listener needs a port or :auto, got: nil")
    port!(:quic, port)
    {port, Keyword.validate!(opts, tls_generate: "localhost")}
  end

  defp quic!(port), do: quic!({port, []})

  @spec port!(atom(), term()) :: :ok
  defp port!(_key, value) when value in [nil, :auto], do: :ok
  defp port!(_key, port) when port in 1..65_535, do: :ok

  defp port!(key, other),
    do:
      raise(ArgumentError, "#{inspect(key)} must be :auto, a port or nil, got: #{inspect(other)}")

  @spec ready!(t()) :: probed_listener() | :none
  defp ready!(%__MODULE__{ready: :auto} = config),
    do: Enum.find([:internal, :web, :tcp], :none, &(Map.fetch!(config, &1) != nil))

  defp ready!(%__MODULE__{ready: :none}), do: :none

  defp ready!(%__MODULE__{ready: listener} = config) when listener in [:internal, :web, :tcp] do
    if Map.fetch!(config, listener) == nil,
      do: raise(ArgumentError, "ready: #{inspect(listener)} probes a listener that is off")

    listener
  end

  defp ready!(%__MODULE__{ready: other}),
    do:
      raise(
        ArgumentError,
        ":ready must be :auto, :none, :internal, :web or :tcp, got: #{inspect(other)}"
      )

  @spec free_port(port_option(), :udp | :tcp, :inet.ip_address()) :: :inet.port_number() | nil
  defp free_port(:auto, :udp, ip) do
    {:ok, socket} = :gen_udp.open(0, [ip: ip] ++ family(ip))
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  defp free_port(:auto, :tcp, ip) do
    {:ok, socket} = :gen_tcp.listen(0, [ip: ip] ++ family(ip))
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp free_port(port_or_nil, _kind, _ip), do: port_or_nil

  @spec family(:inet.ip_address()) :: [:inet6]
  defp family(ip) when tuple_size(ip) == 8, do: [:inet6]
  defp family(_ip), do: []
end
