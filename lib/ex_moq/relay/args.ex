defmodule ExMoQ.Relay.Args do
  @moduledoc false
  # Renders checked `ExMoQ.Relay.Options` as the arguments the relay binary
  # is run with, and as listen addresses.

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Options

  @spec args(Options.t()) :: [String.t()]
  def args(%Options{} = options) do
    tls =
      with {_port, quic_opts} <- options.quic,
           host when host != nil <- quic_opts[:tls_generate] do
        ["--listen-tls-generate", host]
      else
        _no_certificate -> []
      end

    Enum.concat([
      ["--log-level", log_level(options.log_level)],
      listen_flag(options, "--listen", :quic),
      listen_flag(options, "--listen-tcp-bind", :tcp),
      listen_flag(options, "--web-http-listen", :web),
      listen_flag(options, "--internal-listen", :internal),
      tls,
      auth(options.auth),
      options.args
    ])
  end

  @spec listen_flag(Options.t(), String.t(), Options.endpoint()) :: [String.t()]
  defp listen_flag(%Options{} = options, flag, endpoint) do
    case listener(options, endpoint) do
      nil -> []
      {port, ip} -> [flag, address(ip, port)]
    end
  end

  @spec listener(Options.t(), Options.endpoint()) ::
          {:inet.port_number(), :inet.ip_address()} | nil
  def listener(%Options{} = options, endpoint) do
    case Map.fetch!(options, endpoint) do
      nil -> nil
      {port, port_opts} -> {port, Keyword.get(port_opts, :ip, options.ip)}
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

  @spec log_level(Logger.level()) :: String.t()
  defp log_level(level) when level in [:emergency, :alert, :critical, :error], do: "error"
  defp log_level(:warning), do: "warn"
  defp log_level(level) when level in [:notice, :info], do: "info"
  defp log_level(:debug), do: "debug"
end
