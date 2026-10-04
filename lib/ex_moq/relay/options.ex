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
         {:ok, output} <- output(options.output),
         {:ok, log_level} <- log_level(options.log_level),
         {:ok, quic} <- quic(options.quic),
         {:ok, tcp} <- listener(:tcp, options.tcp, []),
         {:ok, web} <- listener(:web, options.web, []),
         {:ok, internal} <- internal(options.internal),
         {:ok, auth} <- auth(options.auth),
         {:ok, _} <- require_listener(quic, tcp) do
      {:ok,
       %__MODULE__{
         binary: binary,
         ip: options.ip,
         quic: quic,
         tcp: tcp,
         web: web,
         internal: internal,
         auth: auth,
         log_level: log_level,
         args: options.args,
         output: output,
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

  @spec binary(Path.t() | nil) :: {:ok, Path.t()} | {:error, String.t()}
  defp binary(binary) do
    case Relay.find_binary(binary) do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, "no moq-relay binary found; see ExMoQ.Relay.find_binary/1"}
    end
  end

  @spec output(term()) :: {:ok, Relay.output()} | {:error, String.t()}
  defp output(output) when output == nil or is_function(output, 1), do: {:ok, output}

  defp output(level) do
    if level in Logger.levels() do
      {:ok, level}
    else
      {:error,
       ":output must be a Logger level, a 1-arity function or nil, got: #{inspect(level)}"}
    end
  end

  @spec log_level(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp log_level(level) when level in @log_levels, do: {:ok, level}

  defp log_level(other) do
    {:error, ":log_level must be one of #{inspect(@log_levels)}, got: #{inspect(other)}"}
  end

  @spec auth(term()) :: {:ok, Relay.auth()} | {:error, String.t()}
  defp auth({:url, url} = auth) when is_binary(url) and url != "", do: {:ok, auth}

  defp auth({:url, other}) do
    {:error, ":auth {:url, url} needs a non-empty string, got: #{inspect(other)}"}
  end

  defp auth(auth) do
    if Keyword.keyword?(auth) do
      case Keyword.validate(auth, [:subscribe, :publish]) do
        {:ok, auth} -> {:ok, auth}
        {:error, keys} -> {:error, "unknown keys #{inspect(keys)}"}
      end
    else
      {:ok, auth}
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

  @spec require_listener(term(), term()) :: {:ok, {term(), term()}} | {:error, String.t()}
  defp require_listener(nil, nil),
    do: {:error, "a relay needs a :quic or a :tcp listener, both are nil"}

  defp require_listener(quic, tcp), do: {:ok, {quic, tcp}}

  @spec listener(atom(), term(), keyword()) :: {:ok, term()} | {:error, String.t()}
  defp listener(key, {port, opts}, defaults) when port != nil and is_list(opts) do
    with {:ok, port} <- port(key, port),
         {:ok, opts} <- opts(opts, [:ip | defaults]) do
      {:ok, {port, opts}}
    end
  end

  defp listener(key, port, _defaults), do: port(key, port)

  @spec opts(keyword(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  defp opts(opts, allowed) do
    case Keyword.validate(opts, allowed) do
      {:ok, opts} -> {:ok, opts}
      {:error, keys} -> {:error, "unknown keys #{inspect(keys)}"}
    end
  end

  @spec port(atom(), term()) :: {:ok, term()} | {:error, String.t()}
  defp port(_key, value) when value in [nil, :auto], do: {:ok, value}
  defp port(_key, port) when port in 1..65_535, do: {:ok, port}

  defp port(key, other) do
    {:error, "#{inspect(key)} must be :auto, a port, {port, opts} or nil, got: #{inspect(other)}"}
  end
end
