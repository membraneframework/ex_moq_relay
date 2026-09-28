defmodule ExMoQ.Test.Relay do
  @moduledoc """
  A relay for ExUnit tests, reached over TCP and stopped with the test.

      relay = ExMoQ.Test.Relay.start_supervised!()
      {:ok, session} = ExMoQ.Native.create_session(relay.url, self(), relay.disable_tls_verify?)
  """

  alias ExMoQ.Relay.Config

  @enforce_keys [:url, :disable_tls_verify?, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{url: String.t(), disable_tls_verify?: boolean(), id: term()}

  @doc """
  Starts a relay under the test supervisor and blocks until it accepts
  connections. `binary` is resolved with `find_binary/1`.

  Raises if there is no binary, or the relay exits or is not ready in time.
  """
  @spec start_supervised!(Path.t() | nil) :: t()
  def start_supervised!(binary \\ nil) do
    config =
      Config.new!(
        binary: binary,
        tcp: :auto,
        quic: nil,
        internal: nil,
        log_level: "info",
        output: :debug
      )

    %{id: id} = spec = Supervisor.child_spec({ExMoQ.Relay, config}, restart: :temporary)
    ExUnit.Callbacks.start_supervised!(spec)
    %__MODULE__{url: ExMoQ.Relay.tcp_url(config), disable_tls_verify?: false, id: id}
  end

  @doc """
  Stops a relay started with `start_supervised!/1`, blocking until it is down.
  """
  @spec stop_supervised!(t()) :: :ok
  def stop_supervised!(%__MODULE__{id: id}),
    do: ExUnit.Callbacks.stop_supervised!(id)

  @doc "See `ExMoQ.Relay.find_binary/1`."
  @spec find_binary(Path.t() | nil) :: Path.t() | nil
  defdelegate find_binary(binary \\ nil), to: ExMoQ.Relay
end
