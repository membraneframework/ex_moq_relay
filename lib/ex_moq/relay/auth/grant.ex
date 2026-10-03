defmodule ExMoQ.Relay.Auth.Grant do
  @moduledoc """
  What a session may do, as the auth server answers.

  A 2xx carrying one of these admits; see [Authentication](https://doc.moq.dev/bin/relay/auth).
  Patterns are relative to `:root` (or the dialed path when it is `nil`).
  """

  @typedoc "Path patterns, like `\"anon/**\"`."
  @type patterns :: [String.t()]

  @type t :: %__MODULE__{
          publish: patterns(),
          subscribe: patterns(),
          root: String.t() | nil,
          mounts: %{optional(String.t()) => String.t()},
          expires: non_neg_integer() | nil,
          revalidate: non_neg_integer() | nil,
          tier: String.t() | nil,
          peer: boolean()
        }

  defstruct publish: [],
            subscribe: [],
            root: nil,
            mounts: %{},
            expires: nil,
            revalidate: nil,
            tier: nil,
            peer: false

  @doc "JSON for a 2xx reply: empty fields are omitted, as on the wire."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = grant) do
    grant
    |> Map.from_struct()
    |> Enum.reject(fn
      {:publish, []} -> true
      {:subscribe, []} -> true
      {:mounts, mounts} when mounts == %{} -> true
      {:peer, false} -> true
      {_key, nil} -> true
      _keep -> false
    end)
    |> Map.new()
    |> Jason.encode!()
  end
end
