defmodule ExMoQ.Test.RelayTest do
  use ExUnit.Case

  alias ExMoQ.Test.Relay

  @moduletag :tmp_dir

  test "raises without a relay binary", %{tmp_dir: dir} do
    assert_raise RuntimeError, ~r/no moq-relay binary/, fn ->
      Relay.start_supervised!(Path.join(dir, "missing"))
    end
  end

  @tag :integration
  test "runs a TCP relay for the test and stops it on request" do
    relay = Relay.start_supervised!()
    assert %Relay{url: "tcp://127.0.0.1:" <> port, disable_tls_verify?: false} = relay

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", String.to_integer(port), [:binary])
    :gen_tcp.close(socket)

    assert :ok = Relay.stop_supervised!(relay)
  end
end
