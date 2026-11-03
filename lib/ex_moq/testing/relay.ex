defmodule ExMoQ.Testing.Relay do
  @moduledoc """
  A relay for ExUnit tests, reached over TCP and stopped with the test.

      %ExMoQ.Relay.Info{tcp: url} = ExMoQ.Testing.Relay.start_supervised!()

  To stop it before the test ends, start it with ExUnit directly:

      relay = start_supervised!({ExMoQ.Relay, ExMoQ.Testing.Relay.options()}, id: :relay)
      ExMoQ.Relay.info(relay).tcp
      stop_supervised!(:relay)
  """

  @doc "Options for a test relay: TCP only, on a port that is free as they are built."
  @spec options(Path.t() | nil) :: ExMoQ.Relay.options()
  def options(binary \\ nil) do
    options = [tcp: free_port(), quic: nil, log_level: :info, output: :debug]
    if binary, do: [{:binary, binary} | options], else: options
  end

  @doc """
  A TCP port nothing listens on right now, for a relay to bind.
  """
  @spec free_port() :: :inet.port_number()
  def free_port() do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
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
end
