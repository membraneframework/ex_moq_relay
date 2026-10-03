defmodule ExMoQ.Relay.Auth.Plug do
  @moduledoc """
  HTTP adapter for `ExMoQ.Relay.Auth`: the relay POSTs JSON here and takes
  the grant in the reply.

      {Bandit, plug: {ExMoQ.Relay.Auth.Plug, MyApp.Auth}, ip: {:local, path}, port: 0}

  Or start both with `ExMoQ.Relay.Auth`.
  """

  @behaviour Plug

  import Plug.Conn

  alias ExMoQ.Relay.Auth.{Grant, Request}

  @impl true
  def init(module) when is_atom(module), do: module

  @impl true
  def call(%{method: "POST"} = conn, module) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, request} <- Request.decode(body) do
      reply(conn, module.admit(request))
    else
      _unreadable -> send_resp(conn, 400, "")
    end
  end

  def call(conn, _module), do: send_resp(conn, 405, "")

  @spec reply(Plug.Conn.t(), {:grant, Grant.t()} | :refuse | :ok) :: Plug.Conn.t()
  defp reply(conn, {:grant, %Grant{} = grant}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Grant.encode(grant))
  end

  defp reply(conn, :ok) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, "{}")
  end

  defp reply(conn, :refuse), do: send_resp(conn, 403, "")
end
