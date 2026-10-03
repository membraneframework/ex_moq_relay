defmodule ExMoQ.Relay.Options do
  @moduledoc false
  # Checks the options of an `ExMoQ.Relay`, and renders them as the arguments
  # the relay binary is run with.

  alias ExMoQ.Relay

  @log_levels ["error", "warn", "info", "debug", "trace"]

  @spec log_levels() :: [String.t()]
  def log_levels(), do: @log_levels

  @spec validate!(Relay.t()) :: Relay.t()
  def validate!(%Relay{} = options) do
    binary = binary!(options.binary)
    output!(options.output)
    log_level!(options.log_level)
    quic = quic!(options.quic)
    Enum.each([:tcp, :web], &listener!(&1, Map.fetch!(options, &1), []))
    internal!(options.internal)
    auth_public!(options.auth_public)

    if quic == nil and options.tcp == nil,
      do: raise(ArgumentError, "a relay needs a :quic or a :tcp listener, both are nil")

    %Relay{options | binary: binary, quic: quic}
  end

  @spec args(Relay.t()) :: [String.t()]
  def args(%Relay{} = options) do
    options = validate!(options)

    listen = fn flag, key ->
      case listener(options, key) do
        nil -> []
        {:auto, ip} -> [flag, address(ip, 0)]
        {port, ip} -> [flag, address(ip, port)]
      end
    end

    grant = fn flag, patterns ->
      case List.wrap(patterns) do
        [] -> []
        list -> [flag, Enum.join(list, ",")]
      end
    end

    auth =
      if Keyword.keyword?(options.auth_public) do
        grant.("--auth-public-subscribe", options.auth_public[:subscribe]) ++
          grant.("--auth-public-publish", options.auth_public[:publish])
      else
        grant.("--auth-public", options.auth_public)
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
      auth ++
      options.args
  end

  @spec listener(Relay.t(), :quic | :tcp | :web | :internal) ::
          {:auto | :inet.port_number(), :inet.ip_address()} | nil
  def listener(%Relay{} = options, key) do
    case Map.fetch!(options, key) do
      nil -> nil
      {port, opts} -> {port, Keyword.get(opts, :ip, options.ip)}
      port -> {port, options.ip}
    end
  end

  @spec address(:inet.ip_address(), :inet.port_number()) :: String.t()
  def address(ip, port) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]:#{port}"
  def address(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  @spec binary!(Path.t() | nil) :: Path.t()
  defp binary!(binary) do
    Relay.find_binary(binary) ||
      raise ArgumentError, "no moq-relay binary found; see ExMoQ.Relay.find_binary/1"
  end

  @spec output!(term()) :: :ok
  defp output!(output) when output == nil or is_function(output, 1), do: :ok

  defp output!(level) do
    if level not in Logger.levels() do
      raise ArgumentError,
            ":output must be a Logger level, a 1-arity function or nil, got: #{inspect(level)}"
    end

    :ok
  end

  @spec log_level!(term()) :: :ok
  defp log_level!(level) when level in @log_levels, do: :ok

  defp log_level!(other) do
    raise ArgumentError,
          ":log_level must be one of #{inspect(@log_levels)}, got: #{inspect(other)}"
  end

  @spec auth_public!(term()) :: :ok
  defp auth_public!(auth_public) do
    if Keyword.keyword?(auth_public), do: Keyword.validate!(auth_public, [:subscribe, :publish])
    :ok
  end

  @spec quic!(term()) :: {:auto | :inet.port_number(), Relay.quic_listener_opts()} | nil
  defp quic!(nil), do: nil

  defp quic!({_port, _opts} = quic), do: listener!(:quic, quic, tls_generate: "localhost")
  defp quic!(port), do: quic!({port, []})

  @spec internal!(term()) :: term()
  defp internal!(internal) do
    if internal == :auto or match?({:auto, _opts}, internal) do
      raise ArgumentError,
            ":internal must be a port or nil: the relay does not report the port it binds for :auto"
    end

    listener!(:internal, internal, [])
  end

  @spec listener!(atom(), term(), keyword()) :: term()
  defp listener!(key, {port, opts}, defaults) when port != nil and is_list(opts) do
    port!(key, port)
    {port, Keyword.validate!(opts, [:ip | defaults])}
  end

  defp listener!(key, port, _defaults) do
    port!(key, port)
    port
  end

  @spec port!(atom(), term()) :: :ok
  defp port!(_key, value) when value in [nil, :auto], do: :ok
  defp port!(_key, port) when port in 1..65_535, do: :ok

  defp port!(key, other) do
    raise ArgumentError,
          "#{inspect(key)} must be :auto, a port, {port, opts} or nil, got: #{inspect(other)}"
  end
end
