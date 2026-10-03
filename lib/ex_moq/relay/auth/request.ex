defmodule ExMoQ.Relay.Auth.Request do
  @moduledoc """
  One auth event from the relay: everything it knows about a session.

  See [Authentication](https://doc.moq.dev/bin/relay/auth). The relay POSTs
  this as JSON; `decode/1` turns the body into a struct for `c:ExMoQ.Relay.Auth.admit/1`.
  """

  @typedoc "Lifecycle event, see `:event`."
  @type event :: :connect | :revalidate | :end

  @typedoc "SETUP AUTHORIZATION TOKEN, unparsed."
  @type token :: %{kind: non_neg_integer(), value: String.t()}

  @typedoc "Verified client certificate facts, when one was presented."
  @type tls :: %{
          optional(:name) => String.t(),
          optional(:fingerprint) => String.t(),
          optional(:expires) => non_neg_integer(),
          optional(:issuer) => String.t()
        }

  @typedoc "Byte totals on an `:end`, from the relay's point of view."
  @type bytes :: %{optional(:sent) => non_neg_integer(), optional(:received) => non_neg_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          event: event(),
          node: String.t(),
          transport: String.t(),
          remote: String.t() | nil,
          local: String.t() | nil,
          server_name: String.t() | nil,
          alpn: String.t() | nil,
          path: String.t(),
          query: String.t() | nil,
          token: token() | nil,
          role: String.t() | nil,
          tls: tls() | nil,
          reason: String.t() | nil,
          duration: float() | nil,
          bytes: bytes() | nil
        }

  @enforce_keys [:id, :event, :node, :transport, :path]
  defstruct [
    :id,
    :event,
    :node,
    :transport,
    :remote,
    :local,
    :server_name,
    :alpn,
    :path,
    :query,
    :token,
    :role,
    :tls,
    :reason,
    :duration,
    :bytes
  ]

  @doc "Decodes a JSON body the relay POSTed. Returns `{:error, reason}` when it is not a request."
  @spec decode(iodata()) :: {:ok, t()} | {:error, term()}
  def decode(body) do
    with {:ok, %{} = map} <- Jason.decode(body),
         {:ok, event} <- event(map["event"]) do
      {:ok,
       %__MODULE__{
         id: map["id"],
         event: event,
         node: map["node"],
         transport: map["transport"],
         remote: map["remote"],
         local: map["local"],
         server_name: map["server_name"],
         alpn: map["alpn"],
         path: map["path"],
         query: map["query"],
         token: token(map["token"]),
         role: map["role"],
         tls: tls(map["tls"]),
         reason: map["reason"],
         duration: map["duration"],
         bytes: bytes(map["bytes"])
       }}
    else
      {:ok, _other} -> {:error, :not_an_object}
      {:error, _reason} = error -> error
    end
  end

  @spec event(term()) :: {:ok, event()} | {:error, {:unknown_event, term()}}
  defp event("connect"), do: {:ok, :connect}
  defp event("revalidate"), do: {:ok, :revalidate}
  defp event("end"), do: {:ok, :end}
  defp event(other), do: {:error, {:unknown_event, other}}

  @spec token(term()) :: token() | nil
  defp token(%{"kind" => kind, "value" => value}) when is_integer(kind) and is_binary(value),
    do: %{kind: kind, value: value}

  defp token(_other), do: nil

  @spec tls(term()) :: tls() | nil
  defp tls(%{} = map),
    do:
      take(map, [
        {"name", :name},
        {"fingerprint", :fingerprint},
        {"expires", :expires},
        {"issuer", :issuer}
      ])

  defp tls(_other), do: nil

  @spec bytes(term()) :: bytes() | nil
  defp bytes(%{} = map), do: take(map, [{"sent", :sent}, {"received", :received}])
  defp bytes(_other), do: nil

  @spec take(map(), [{String.t(), atom()}]) :: map()
  defp take(map, keys) do
    for {key, atom} <- keys, Map.has_key?(map, key), into: %{}, do: {atom, Map.fetch!(map, key)}
  end
end
