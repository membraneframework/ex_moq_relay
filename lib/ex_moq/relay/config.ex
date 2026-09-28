defmodule ExMoQ.Relay.Config do
  @moduledoc """
  What `ExMoQ.Relay` runs, built with `new!/1`:

      config = ExMoQ.Relay.Config.new!(tcp: :auto, web: :auto)
      config.tcp  #=> 54321

  A config from `new!/1` has every port chosen, so the relay's URLs are known
  before it starts. `ExMoQ.Relay` expects such a config; a hand-built
  `%Config{}` is not checked.

  ## Options

    * `:binary` - path to the relay. Defaults to `$MOQ_RELAY`, then
      `moq-relay` on `$PATH`.
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
    * `:on_output` - a function called with each output line. Without one,
      lines are logged at `:log_output` (default `:info`; `nil` drops them).
    * `:ready` - the listener probed before `start_link` returns: `:internal`,
      `:web`, `:tcp` or `:none`. The default, `:auto`, is the first of those
      that is on.
    * `:ready_timeout` - milliseconds to wait for readiness (default 15 000).
    * `:name` - a name to register the relay's process under (default `nil`).

  `:auto` means a port that is free when `new!/1` picks it; another process
  can take it before the relay binds it.
  """

  @typedoc "A listener port as given to `new!/1`."
  @type port_option :: :auto | :inet.port_number() | nil

  @typedoc "The QUIC listener as given to `new!/1`."
  @type quic_option :: port_option() | {:auto | :inet.port_number(), quic_listener_opts()}

  @typedoc "Options of the QUIC listener, for `{port, opts}` in `:quic`."
  @type quic_listener_opts :: [{:tls_generate, String.t() | nil}]

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
          | {:on_output, (String.t() -> any()) | nil}
          | {:log_output, Logger.level() | nil}
          | {:ready, :auto | probed_listener() | :none}
          | {:ready_timeout, non_neg_integer()}
          | {:name, GenServer.name() | nil}

  @type t :: %__MODULE__{
          binary: Path.t() | nil,
          ip: :inet.ip_address(),
          quic: {:inet.port_number(), quic_listener_opts()} | nil,
          tcp: :inet.port_number() | nil,
          web: :inet.port_number() | nil,
          internal: :inet.port_number() | nil,
          auth_public: String.t() | [String.t()] | nil,
          log_level: String.t(),
          args: [String.t()],
          on_output: (String.t() -> any()) | nil,
          log_output: Logger.level() | nil,
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
            on_output: nil,
            log_output: :info,
            ready: :auto,
            ready_timeout: 15_000,
            name: nil

  @doc """
  Builds a config from options, choosing a free port for each `:auto`
  listener.

  Raises `KeyError` for an unknown option and `ArgumentError` for a value or
  combination the relay cannot run with.
  """
  @spec new!([option()]) :: t()
  def new!(opts \\ []) when is_list(opts) do
    %__MODULE__{ip: ip} = config = struct!(__MODULE__, opts)
    quic = quic!(config.quic)
    Enum.each([:tcp, :web, :internal], &port!(&1, Map.fetch!(config, &1)))

    if quic == nil and config.tcp == nil,
      do: raise(ArgumentError, "a relay needs a :quic or a :tcp listener, both are nil")

    config = %__MODULE__{
      config
      | quic: with({port, tls} <- quic, do: {free_port(port, :udp, ip), tls}),
        tcp: free_port(config.tcp, :tcp, ip),
        web: free_port(config.web, :tcp, ip),
        internal: free_port(config.internal, :tcp, ip)
    }

    %__MODULE__{config | ready: ready!(config)}
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
