defmodule ExMoQ.Test.Relay do
  @moduledoc """
  Runs a MoQ relay for ExUnit integration tests: an `ExMoQ.Relay` with a
  plaintext TCP listener, supervised by the current test.

  `start_supervised!/1` starts a relay under the current test supervisor and
  blocks until it accepts connections:

      relay = ExMoQ.Test.Relay.start_supervised!()
      {:ok, session} = ExMoQ.Native.create_session(relay.url, self(), relay.disable_tls_verify?)

  Call it in `setup_all` for a relay shared by the test module, or inside a
  single test when it needs its own instance. Depend on `:ex_moq_relay` in
  the test environment only: `{:ex_moq_relay, "~> 0.1.0", only: :test}`.

  The relay listens on TCP for lossless transport, but groups can still be
  dropped as part of eviction policies.
  """

  @enforce_keys [:url, :disable_tls_verify?, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{url: String.t(), disable_tls_verify?: boolean(), id: term()}
  @type option :: {:binary, Path.t()}

  @doc """
  Starts a relay under the ExUnit test supervisor and blocks until it
  accepts connections.

  The relay can be stopped mid-test with `stop_supervised!/1`.

  Raises if no moq-relay binary is found, or if the relay exits or does not
  accept connections in time.
  """
  @spec start_supervised!([option()]) :: t()
  def start_supervised!(opts \\ []) do
    binary =
      find_binary(opts) ||
        raise """
        no moq-relay binary for the integration tests; provide one of:
          * the :binary option — path to a moq-relay binary
          * MOQ_RELAY — path to a moq-relay binary
          * moq-relay on $PATH (e.g. installed with `cargo install moq-relay`)
        """

    id = {__MODULE__, make_ref()}

    relay_opts = [
      binary: binary,
      tcp: :auto,
      quic: nil,
      internal: nil,
      log_level: "info",
      log_output: :debug
    ]

    relay =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({ExMoQ.Relay, relay_opts}, id: id, restart: :temporary)
      )

    %__MODULE__{url: ExMoQ.Relay.tcp_url(relay), disable_tls_verify?: false, id: id}
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
  @spec find_binary([option()]) :: Path.t() | nil
  defdelegate find_binary(opts \\ []), to: ExMoQ.Relay
end
