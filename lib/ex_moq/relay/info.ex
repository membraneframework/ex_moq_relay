defmodule ExMoQ.Relay.Info do
  @moduledoc """
  What a started relay reports, from `ExMoQ.Relay.info/1`: where its
  listeners are reached, with the ports it bound for `:auto`. A listener
  that is off is `nil`.

    * `:quic_url` - `https://host:port` of the QUIC listener; append the
      path yourself.
    * `:tcp_url` - `tcp://host:port` of the TCP listener.
    * `:web_url` - `http://host:port` of the web listener.
    * `:internal_url` - `http://host:port` of the internal listener.
    * `:tls` - the QUIC listener's certificate: `:generated` when the relay
      generated a self-signed one, which clients cannot verify and must pin
      by fingerprint (served on the web listener at `/certificate.sha256`) or
      skip verifying; `:provided` when it was passed in `:args`; `nil` without
      a QUIC listener. The TCP listener is always plaintext.

  A listener bound to an unspecified address (`0.0.0.0` or `::`) is reached
  on the loopback one.
  """

  alias ExMoQ.Relay
  alias ExMoQ.Relay.Args
  alias ExMoQ.Relay.Options

  @type t :: %__MODULE__{
          quic_url: String.t() | nil,
          tcp_url: String.t() | nil,
          web_url: String.t() | nil,
          internal_url: String.t() | nil,
          tls: :generated | :provided | nil
        }

  @enforce_keys [:quic_url, :tcp_url, :web_url, :internal_url, :tls]
  defstruct @enforce_keys

  @doc false
  @spec new(Options.t()) :: t()
  def new(%Options{} = options) do
    %__MODULE__{
      quic_url: url(options, "https", :quic),
      tcp_url: url(options, "tcp", :tcp),
      web_url: url(options, "http", :web),
      internal_url: url(options, "http", :internal),
      tls: tls(options.quic)
    }
  end

  @spec tls(Relay.quic()) :: :generated | :provided | nil
  defp tls(nil), do: nil
  defp tls({_port, opts}), do: if(opts[:tls_generate], do: :generated, else: :provided)

  @spec url(Options.t(), String.t(), :quic | :tcp | :web | :internal) :: String.t() | nil
  defp url(options, scheme, key) do
    case Args.listener(options, key) do
      nil -> nil
      {port, ip} when is_integer(port) -> "#{scheme}://#{Args.address(reachable(ip), port)}"
    end
  end

  @spec reachable(:inet.ip_address()) :: :inet.ip_address()
  defp reachable({0, 0, 0, 0}), do: {127, 0, 0, 1}
  defp reachable({0, 0, 0, 0, 0, 0, 0, 0}), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp reachable(ip), do: ip
end
