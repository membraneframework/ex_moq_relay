defmodule ExMoQ.Relay.Auth.GrantTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay.Auth.Grant

  test "encodes the cross-language grant vector" do
    grant = %Grant{
      publish: ["alice/**"],
      subscribe: ["**"],
      root: "pid/room",
      expires: 4_102_444_800,
      revalidate: 60,
      tier: "websocket",
      peer: true
    }

    assert Jason.decode!(Grant.encode(grant)) == %{
             "publish" => ["alice/**"],
             "subscribe" => ["**"],
             "root" => "pid/room",
             "expires" => 4_102_444_800,
             "revalidate" => 60,
             "tier" => "websocket",
             "peer" => true
           }
  end

  test "omits empty fields and encodes mounts as an object" do
    grant = %Grant{subscribe: ["**"], mounts: %{".svc" => ".svc/pid"}}

    assert Jason.decode!(Grant.encode(grant)) == %{
             "subscribe" => ["**"],
             "mounts" => %{".svc" => ".svc/pid"}
           }

    assert Jason.decode!(Grant.encode(%Grant{publish: ["**"]})) == %{"publish" => ["**"]}
  end
end
