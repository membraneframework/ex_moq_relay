defmodule ExMoQ.Test.Relay do
  @moduledoc """
  A relay for ExUnit tests, reached over TCP and stopped with the test.

      %ExMoQ.Relay.Info{tcp_url: url} = ExMoQ.Test.Relay.start_supervised!()

  To stop it before the test ends, start it with ExUnit directly:

      relay = start_supervised!({ExMoQ.Relay, ExMoQ.Test.Relay.options()}, id: :relay)
      ExMoQ.Relay.info(relay).tcp_url
      stop_supervised!(:relay)
  """

  @doc """
  The options of a test relay: TCP only, on a port the relay picks, with its
  output logged at `:debug`. `binary` is resolved with `find_binary/1`.
  """
  @spec options(Path.t() | nil) :: ExMoQ.Relay.t()
  def options(binary \\ nil) do
    %ExMoQ.Relay{binary: binary, tcp: :auto, quic: nil, log_level: "info", output: :debug}
  end

  @doc """
  Starts a relay with `options/1` under the test supervisor and blocks until
  it is ready.

  Raises if there is no binary, or the relay exits or is not ready in time.
  """
  @spec start_supervised!(Path.t() | nil) :: ExMoQ.Relay.Info.t()
  def start_supervised!(binary \\ nil) do
    {ExMoQ.Relay, options(binary)}
    |> ExUnit.Callbacks.start_supervised!(restart: :temporary)
    |> ExMoQ.Relay.info()
  end

  @doc "See `ExMoQ.Relay.find_binary/1`."
  @spec find_binary(Path.t() | nil) :: Path.t() | nil
  defdelegate find_binary(binary \\ nil), to: ExMoQ.Relay
end
