defmodule ExMoQ.Relay.Auth.RequestTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay.Auth.Request

  # Cross-language vector from moq-auth's request.rs.
  @connect ~s({"id":"00ff","event":"connect","node":"relay-1","transport":"quic","path":"/demo/room","token":{"kind":1,"value":"APv_"}})
  @end_event ~s({"id":"00ff","event":"end","reason":"expired","duration":1.5,"bytes":{"sent":10,"received":20},"node":"relay-1","transport":"websocket","remote":"203.0.113.9:4433","path":"/demo/room","query":"jwt=abc"})

  test "decodes a connect request" do
    assert {:ok,
            %Request{
              id: "00ff",
              event: :connect,
              node: "relay-1",
              transport: "quic",
              path: "/demo/room",
              token: %{kind: 1, value: "APv_"},
              query: nil,
              reason: nil
            }} = Request.decode(@connect)
  end

  test "decodes an end request with bytes and query" do
    assert {:ok,
            %Request{
              event: :end,
              reason: "expired",
              duration: 1.5,
              bytes: %{sent: 10, received: 20},
              transport: "websocket",
              remote: "203.0.113.9:4433",
              query: "jwt=abc"
            }} = Request.decode(@end_event)
  end

  test "refuses a body that is not a request" do
    assert {:error, _reason} = Request.decode("[]")
    assert {:error, {:unknown_event, "nope"}} = Request.decode(~s({"event":"nope"}))
  end
end
