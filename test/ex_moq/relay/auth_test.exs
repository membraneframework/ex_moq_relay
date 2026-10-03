defmodule ExMoQ.Relay.AuthTest do
  use ExUnit.Case, async: true

  alias ExMoQ.Relay.Auth
  alias ExMoQ.Relay.Auth.Grant

  defmodule SubscribeAll do
    @behaviour Auth

    @impl true
    def admit(%{event: :end}), do: :ok
    def admit(_request), do: {:grant, %Grant{subscribe: ["**"]}}
  end

  test "url/1 and socket_path/0 build a unix auth URL" do
    socket = Auth.socket_path()
    assert String.ends_with?(socket, ".sock")
    assert Auth.url(socket) == "unix://" <> socket
  end

  test "starts an HTTP server the relay can reach over a Unix socket" do
    socket = Auth.socket_path()
    start_supervised!({Auth, module: SubscribeAll, socket: socket})

    assert {200, body} = post(socket, ~s({"id":"1","event":"connect","node":"n","transport":"tcp","path":"/"}))
    assert Jason.decode!(body) == %{"subscribe" => ["**"]}
  end

  defp post(socket, body) do
    {:ok, conn} = :gen_tcp.connect({:local, socket}, 0, [:binary, active: false])

    request = [
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ]

    :ok = :gen_tcp.send(conn, request)
    {:ok, response} = read(conn)
    :gen_tcp.close(conn)

    [status_line | rest] = String.split(response, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ")
    body = rest |> Enum.join("\r\n") |> String.split("\r\n\r\n", parts: 2) |> List.last()
    {String.to_integer(status), body}
  end

  defp read(conn, acc \\ "") do
    case :gen_tcp.recv(conn, 0, 2_000) do
      {:ok, data} -> read(conn, acc <> data)
      {:error, :closed} when acc != "" -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end
end
