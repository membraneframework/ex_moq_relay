defmodule ExMoQ.Testing.RelayTest do
  use ExUnit.Case

  alias ExMoQ.Relay.Info
  alias ExMoQ.Testing.Relay

  @tag :integration
  test "runs a TCP relay for the test" do
    assert %Info{tcp: "tcp://127.0.0.1:" <> port, quic: nil} =
             Relay.start_supervised!()

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", String.to_integer(port), [:binary])
    :gen_tcp.close(socket)
  end
end
