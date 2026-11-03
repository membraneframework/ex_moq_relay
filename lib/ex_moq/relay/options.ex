defmodule ExMoQ.Relay.Options do
  @moduledoc false
  # Used internally by `ExMoQ.Relay`

  alias ExMoQ.Relay

  @levels Logger.levels()

  @type endpoint :: :quic | :tcp | :web | :internal

  @type listener :: {:inet.port_number(), Relay.listener_opts()}
  @type quic_listener :: {:inet.port_number(), Relay.quic_listener_opts()}

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          auth: Relay.auth() | nil,
          log_level: Logger.level(),
          args: [String.t()],
          output: Relay.output() | nil,
          ready_timeout: non_neg_integer(),
          name: GenServer.name() | nil,
          quic: quic_listener() | nil,
          tcp: listener() | nil,
          web: listener() | nil,
          internal: listener() | nil
        }

  @enforce_keys [
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

  @spec validate(Relay.options()) :: {:ok, t()} | {:error, String.t()}
  def validate(options) do
    with {:ok, options} <- opts(options, @enforce_keys),
         {:ok, output} <- output(options[:output]),
         {:ok, log_level} <- log_level(options[:log_level]),
         {:ok, quic} <- listener(:quic, options[:quic], tls_generate: "localhost"),
         {:ok, tcp} <- listener(:tcp, options[:tcp], []),
         {:ok, web} <- listener(:web, options[:web], []),
         {:ok, internal} <- listener(:internal, options[:internal], []),
         {:ok, auth} <- auth(options[:auth]),
         :ok <- require_listener(quic, tcp) do
      {:ok,
       %__MODULE__{
         ip: options[:ip],
         quic: quic,
         tcp: tcp,
         web: web,
         internal: internal,
         auth: auth,
         log_level: log_level,
         args: options[:args],
         output: output,
         ready_timeout: options[:ready_timeout],
         name: options[:name]
       }}
    end
  end

  @spec validate!(Relay.options()) :: t()
  def validate!(options) do
    case validate(options) do
      {:ok, options} -> options
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec output(term()) :: {:ok, Relay.output() | nil} | {:error, String.t()}
  defp output(output) when output == nil or is_function(output, 1), do: {:ok, output}
  defp output(level) when level in @levels, do: {:ok, level}

  defp output(other) do
    {:error, ":output must be a Logger level, a 1-arity function or nil, got: #{inspect(other)}"}
  end

  @spec log_level(term()) :: {:ok, Logger.level()} | {:error, String.t()}
  defp log_level(level) when level in @levels, do: {:ok, level}

  defp log_level(other) do
    {:error, ":log_level must be a Logger level, got: #{inspect(other)}"}
  end

  @spec auth(term()) :: {:ok, Relay.auth() | nil} | {:error, String.t()}
  defp auth(nil), do: {:ok, nil}
  defp auth({:url, url} = auth) when is_binary(url) and url != "", do: {:ok, auth}

  defp auth({:url, other}) do
    {:error, ":auth {:url, url} needs a non-empty string, got: #{inspect(other)}"}
  end

  defp auth(pattern) when is_binary(pattern), do: {:ok, pattern}

  defp auth(auth) when is_list(auth) do
    if Keyword.keyword?(auth) do
      case Keyword.validate(auth, [:subscribe, :publish]) do
        {:ok, auth} -> {:ok, auth}
        {:error, keys} -> {:error, "unknown keys #{inspect(keys)}"}
      end
    else
      {:ok, auth}
    end
  end

  @spec require_listener(term(), term()) :: :ok | {:error, String.t()}
  defp require_listener(nil, nil),
    do: {:error, "a relay needs a :quic or a :tcp listener"}

  defp require_listener(_quic, _tcp), do: :ok

  @spec listener(endpoint(), term(), keyword()) ::
          {:ok, listener() | quic_listener() | nil} | {:error, String.t()}
  defp listener(_key, nil, _defaults), do: {:ok, nil}

  defp listener(key, {port, opts}, defaults) when is_list(opts) do
    with {:ok, port} <- port(key, port),
         {:ok, opts} <- opts(opts, [:ip | defaults]) do
      {:ok, {port, opts}}
    end
  end

  defp listener(key, port, defaults), do: listener(key, {port, []}, defaults)

  @spec opts(keyword(), [atom() | {atom(), term()}]) :: {:ok, keyword()} | {:error, String.t()}
  defp opts(opts, allowed) do
    case Keyword.validate(opts, allowed) do
      {:ok, opts} -> {:ok, opts}
      {:error, keys} -> {:error, "unknown keys #{inspect(keys)}"}
    end
  end

  @spec port(endpoint(), term()) :: {:ok, :inet.port_number()} | {:error, String.t()}
  defp port(_key, port) when port in 1..65_535, do: {:ok, port}

  defp port(key, other) do
    {:error, "#{inspect(key)} must be a port or {port, opts}, got: #{inspect(other)}"}
  end
end
