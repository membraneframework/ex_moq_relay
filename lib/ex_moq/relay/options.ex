defmodule ExMoQ.Relay.Options do
  @moduledoc false
  # Checked options of an `ExMoQ.Relay`. Built only by `validate/1`; the
  # relay and its helpers take this struct and do not validate again.

  alias ExMoQ.Relay

  @log_levels ["error", "warn", "info", "debug", "trace"]

  @type t :: %__MODULE__{
          binary: Path.t(),
          ip: :inet.ip_address(),
          quic: Relay.quic_option(),
          tcp: Relay.listener_option(),
          web: Relay.listener_option(),
          internal: :inet.port_number() | {:inet.port_number(), Relay.listener_opts()} | nil,
          auth: Relay.auth(),
          log_level: String.t(),
          args: [String.t()],
          output: Relay.output(),
          ready_timeout: non_neg_integer(),
          name: GenServer.name() | nil
        }

  @enforce_keys [
    :binary,
    :ip,
    :quic,
    :tcp,
    :web,
    :internal,
    :auth,
    :log_level,
    :args,
    :output,
    :ready_timeout,
    :name
  ]
  defstruct @enforce_keys

  @spec log_levels() :: [String.t()]
  def log_levels(), do: @log_levels

  @spec validate(Relay.t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%Relay{} = options) do
    with {:ok, binary} <- binary(options.binary),
         :ok <- output(options.output),
         :ok <- log_level(options.log_level),
         {:ok, quic} <- quic(options.quic),
         {:ok, tcp} <- listener(:tcp, options.tcp, []),
         {:ok, web} <- listener(:web, options.web, []),
         {:ok, internal} <- internal(options.internal),
         :ok <- auth(options.auth),
         :ok <- require_listener(quic, tcp) do
      {:ok,
       %__MODULE__{
         binary: binary,
         ip: options.ip,
         quic: quic,
         tcp: tcp,
         web: web,
         internal: internal,
         auth: options.auth,
         log_level: options.log_level,
         args: options.args,
         output: options.output,
         ready_timeout: options.ready_timeout,
         name: options.name
       }}
    end
  end

  @spec validate!(Relay.t()) :: t()
  def validate!(%Relay{} = options) do
    case validate(options) do
      {:ok, options} -> options
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec args(t()) :: [String.t()]
  def args(%__MODULE__{} = options) do
    listen = fn flag, key ->
      case listener(options, key) do
        nil -> []
        {:auto, ip} -> [flag, address(ip, 0)]
        {port, ip} -> [flag, address(ip, port)]
      end
    end

    tls =
      with {_port, opts} <- options.quic,
           host when host != nil <- opts[:tls_generate] do
        ["--listen-tls-generate", host]
      else
        _no_certificate -> []
      end

    ["--log-level", options.log_level] ++
      listen.("--listen", :quic) ++
      listen.("--listen-tcp-bind", :tcp) ++
      listen.("--web-http-listen", :web) ++
      listen.("--internal-listen", :internal) ++
      tls ++
      auth_args(options.auth) ++
      options.args
  end

  @spec listener(t(), :quic | :tcp | :web | :internal) ::
          {:auto | :inet.port_number(), :inet.ip_address()} | nil
  def listener(%__MODULE__{} = options, key) do
    case Map.fetch!(options, key) do
      nil -> nil
      {port, opts} -> {port, Keyword.get(opts, :ip, options.ip)}
      port -> {port, options.ip}
    end
  end

  @spec address(:inet.ip_address(), :inet.port_number()) :: String.t()
  def address(ip, port) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]:#{port}"
  def address(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  @spec binary(Path.t() | nil) :: {:ok, Path.t()} | {:error, String.t()}
  defp binary(binary) do
    case Relay.find_binary(binary) do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, "no moq-relay binary found; see ExMoQ.Relay.find_binary/1"}
    end
  end

  @spec output(term()) :: :ok | {:error, String.t()}
  defp output(output) when output == nil or is_function(output, 1), do: :ok

  defp output(level) do
    if level in Logger.levels() do
      :ok
    else
      {:error,
       ":output must be a Logger level, a 1-arity function or nil, got: #{inspect(level)}"}
    end
  end

  @spec log_level(term()) :: :ok | {:error, String.t()}
  defp log_level(level) when level in @log_levels, do: :ok

  defp log_level(other) do
    {:error, ":log_level must be one of #{inspect(@log_levels)}, got: #{inspect(other)}"}
  end

  @spec auth_args(Relay.auth()) :: [String.t()]
  defp auth_args({:url, url}), do: ["--auth-url", url]
  defp auth_args(nil), do: []

  defp auth_args(auth) do
    grant = fn flag, patterns ->
      case List.wrap(patterns) do
        [] -> []
        list -> [flag, Enum.join(list, ",")]
      end
    end

    if Keyword.keyword?(auth) do
      grant.("--auth-public-subscribe", auth[:subscribe]) ++
        grant.("--auth-public-publish", auth[:publish])
    else
      grant.("--auth-public", auth)
    end
  end

  @spec auth(term()) :: :ok | {:error, String.t()}
  defp auth({:url, url}) when is_binary(url) and url != "", do: :ok

  defp auth({:url, other}) do
    {:error, ":auth {:url, url} needs a non-empty string, got: #{inspect(other)}"}
  end

  defp auth(auth) do
    if Keyword.keyword?(auth) do
      case Keyword.validate(auth, [:subscribe, :publish]) do
        {:ok, _auth} -> :ok
        {:error, keys} -> {:error, "unknown keys #{inspect(keys)}"}
      end
    else
      :ok
    end
  end

  @spec quic(term()) ::
          {:ok, {:auto | :inet.port_number(), Relay.quic_listener_opts()} | nil}
          | {:error, String.t()}
  defp quic(nil), do: {:ok, nil}

  defp quic({_port, _opts} = quic), do: listener(:quic, quic, tls_generate: "localhost")
  defp quic(port), do: quic({port, []})

  @spec internal(term()) :: {:ok, term()} | {:error, String.t()}
  defp internal(internal) do
    if internal == :auto or match?({:auto, _opts}, internal) do
      {:error,
       ":internal must be a port or nil: the relay does not report the port it binds for :auto"}
    else
      listener(:internal, internal, [])
    end
  end

  @spec require_listener(term(), term()) :: :ok | {:error, String.t()}
  defp require_listener(nil, nil),
    do: {:error, "a relay needs a :quic or a :tcp listener, both are nil"}

  defp require_listener(_quic, _tcp), do: :ok

  @spec listener(atom(), term(), keyword()) :: {:ok, term()} | {:error, String.t()}
  defp listener(key, {port, opts}, defaults) when port != nil and is_list(opts) do
    with :ok <- port(key, port),
         {:ok, opts} <- validate_opts(opts, [:ip | defaults]) do
      {:ok, {port, opts}}
    end
  end

  defp listener(key, port, _defaults) do
    with :ok <- port(key, port), do: {:ok, port}
  end

  @spec validate_opts(keyword(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp validate_opts(opts, allowed) do
    case Keyword.validate(opts, allowed) do
      {:ok, opts} -> {:ok, opts}
      {:error, keys} -> {:error, "unknown keys #{inspect(keys)}"}
    end
  end

  @spec port(atom(), term()) :: :ok | {:error, String.t()}
  defp port(_key, value) when value in [nil, :auto], do: :ok
  defp port(_key, port) when port in 1..65_535, do: :ok

  defp port(key, other) do
    {:error, "#{inspect(key)} must be :auto, a port, {port, opts} or nil, got: #{inspect(other)}"}
  end
end
