defmodule ExMoQ.Relay.Args do
  @moduledoc false
  # Renders checked `ExMoQ.Relay.Options` as the arguments the relay binary
  # is run with, and as listen addresses.

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Options

  @spec args(Options.t()) :: [String.t()]
  def args(%Options{} = options) do
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
      auth(options.auth) ++
      options.args
  end

  @spec listener(Options.t(), :quic | :tcp | :web | :internal) ::
          {:auto | :inet.port_number(), :inet.ip_address()} | nil
  def listener(%Options{} = options, key) do
    case Map.fetch!(options, key) do
      nil -> nil
      {port, opts} -> {port, Keyword.get(opts, :ip, options.ip)}
      port -> {port, options.ip}
    end
  end

  @spec address(:inet.ip_address(), :inet.port_number()) :: String.t()
  def address(ip, port) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]:#{port}"
  def address(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  @spec auth(Relay.auth()) :: [String.t()]
  defp auth({:url, url}), do: ["--auth-url", url]
  defp auth(nil), do: []

  defp auth(auth) do
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
end
