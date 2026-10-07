defmodule ExMoQ.Relay.Args do
  @moduledoc false
  # Renders checked `ExMoQ.Relay.Options` as the arguments the relay binary
  # is run with, and as listen addresses.

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Options

  @typep endpoint :: :quic | :tcp | :web | :internal

  @spec args(Options.t()) :: [String.t()]
  def args(%Options{} = options) do
    tls =
      with {_port, opts} <- options.quic,
           host when host != nil <- opts[:tls_generate] do
        ["--listen-tls-generate", host]
      else
        _no_certificate -> []
      end

    Enum.concat([
      ["--log-level", options.log_level],
      listen_flag(options, "--listen", :quic),
      listen_flag(options, "--listen-tcp-bind", :tcp),
      listen_flag(options, "--web-http-listen", :web),
      listen_flag(options, "--internal-listen", :internal),
      tls,
      auth(options.auth),
      options.args
    ])
  end

  @spec listen_flag(Options.t(), String.t(), endpoint()) :: [String.t()]
  defp listen_flag(%Options{} = options, flag, key) do
    case listener(options, key) do
      nil -> []
      {:auto, ip} -> [flag, address(ip, 0)]
      {port, ip} -> [flag, address(ip, port)]
    end
  end

  @spec listener(Options.t(), endpoint()) ::
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
    if Keyword.keyword?(auth) do
      auth_flag("--auth-public-subscribe", auth[:subscribe]) ++
        auth_flag("--auth-public-publish", auth[:publish])
    else
      auth_flag("--auth-public", auth)
    end
  end

  @spec auth_flag(String.t(), Relay.auth()) :: [String.t()]
  defp auth_flag(flag, patterns) do
    case List.wrap(patterns) do
      [] -> []
      list -> [flag, Enum.join(list, ",")]
    end
  end
end
