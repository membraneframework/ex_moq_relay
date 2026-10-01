defmodule ExMoQ.Test.RelayTest do
  use ExUnit.Case

  alias ExMoQ.Relay.Info
  alias ExMoQ.Test.Relay

  test "raises without a relay binary" do
    assert_raise ArgumentError, ~r/no moq-relay binary/, fn ->
      Relay.start_supervised!("/nonexistent/moq-relay")
    end
  end

  @tag :integration
  test "runs a TCP relay for the test" do
    assert %Info{tcp_url: "tcp://127.0.0.1:" <> port, quic_url: nil, tls: nil} =
             Relay.start_supervised!()

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", String.to_integer(port), [:binary])
    :gen_tcp.close(socket)
  end

  @tag :integration
  test "its options run a relay the test can stop" do
    relay = start_supervised!({ExMoQ.Relay, Relay.options()}, id: :relay)
    assert %Info{tcp_url: "tcp://" <> _address} = ExMoQ.Relay.info(relay)

    assert :ok = stop_supervised!(:relay)
    refute Process.alive?(relay)
  end
end
