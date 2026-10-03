defmodule ExMoQ.Relay.Auth.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ExMoQ.Relay.Auth.{Grant, Plug, Request}

  defmodule EveryoneSubscribes do
    @behaviour ExMoQ.Relay.Auth

    @impl true
    def admit(%Request{event: :end}), do: :ok
    def admit(%Request{path: "/deny"}), do: :refuse
    def admit(%Request{}), do: {:grant, %Grant{subscribe: ["**"]}}
  end

  defp post(body) do
    :post
    |> conn("/", body)
    |> put_req_header("content-type", "application/json")
    |> Plug.call(EveryoneSubscribes)
  end

  test "admits with a grant, refuses, and acknowledges end" do
    connect = ~s({"id":"1","event":"connect","node":"n","transport":"tcp","path":"/live"})
    assert %{status: 200, resp_body: body} = post(connect)
    assert Jason.decode!(body) == %{"subscribe" => ["**"]}

    deny = ~s({"id":"2","event":"connect","node":"n","transport":"tcp","path":"/deny"})
    assert %{status: 403} = post(deny)

    ended =
      ~s({"id":"1","event":"end","reason":"expired","duration":1.0,"bytes":{"sent":0,"received":0},"node":"n","transport":"tcp","path":"/live"})

    assert %{status: 200, resp_body: "{}"} = post(ended)
  end

  test "rejects a bad body or method" do
    assert %{status: 400} = post("not-json")
    assert %{status: 405} = Plug.call(conn(:get, "/"), EveryoneSubscribes)
  end
end
