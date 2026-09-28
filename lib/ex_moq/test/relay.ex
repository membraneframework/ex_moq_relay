defmodule ExMoQ.Test.Relay do
  @moduledoc """
  A relay for ExUnit tests, on a free TCP port and stopped with the test.

      relay = ExMoQ.Test.Relay.start_supervised!()
      {:ok, session} = ExMoQ.Native.create_session(relay.url, self(), relay.disable_tls_verify?)
  """

  alias ExMoQ.Relay.Config

  @enforce_keys [:url, :disable_tls_verify?, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{url: String.t(), disable_tls_verify?: boolean(), id: term()}

  @doc """
  Starts a relay under the ExUnit test supervisor and blocks until it
  accepts connections.

  The relay can be stopped mid-test with `stop_supervised!/1`.

  Raises if no moq-relay binary is found, or if the relay exits or does not
  accept connections in time.
  """
  @spec start_supervised!(Path.t() | nil) :: t()
  def start_supervised!(binary \\ nil) do
    binary =
      find_binary(binary) ||
        raise """
        no moq-relay binary for the integration tests; provide one of:
          * a path passed to start_supervised!/1
          * MOQ_RELAY — path to a moq-relay binary
          * moq-relay on $PATH (e.g. installed with `cargo install moq-relay`)
        """

    id = {__MODULE__, make_ref()}

    config =
      Config.new!(
        binary: binary,
        tcp: :auto,
        quic: nil,
        internal: nil,
        log_level: "info",
        log_output: :debug
      )

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({ExMoQ.Relay, config}, id: id, restart: :temporary)
    )

    %__MODULE__{url: ExMoQ.Relay.tcp_url(config), disable_tls_verify?: false, id: id}
  end

  @doc """
  Stops a relay started with `start_supervised!/1`, blocking until it is down.
  """
  @spec stop_supervised!(t()) :: :ok
  def stop_supervised!(%__MODULE__{id: id}),
    do: ExUnit.Callbacks.stop_supervised!(id)

  @doc """
  Resolves the moq-relay binary like `ExMoQ.Relay.find_binary/1`.
  """
  @spec find_binary(Path.t() | nil) :: Path.t() | nil
  defdelegate find_binary(binary \\ nil), to: ExMoQ.Relay
end
