defmodule ExMoQ.Relay.Auth do
  @moduledoc """
  An auth server for a relay's `auth: {:url, url}`.

  The relay POSTs every session's `connect`, `revalidate` and `end` as JSON
  and takes the grant in the reply
  ([contract](https://doc.moq.dev/bin/relay/auth)). Implement `c:admit/1`,
  then either plug it into your own HTTP server or start one here on a Unix
  socket:

      defmodule MyApp.Auth do
        @behaviour ExMoQ.Relay.Auth

        @impl true
        def admit(%{event: :end}), do: :ok

        def admit(request) do
          if publisher?(request),
            do: {:grant, %ExMoQ.Relay.Auth.Grant{publish: ["**"], subscribe: ["**"]}},
            else: {:grant, %ExMoQ.Relay.Auth.Grant{subscribe: ["**"]}}
        end
      end

      socket = ExMoQ.Relay.Auth.socket_path()

      children = [
        {ExMoQ.Relay.Auth, module: MyApp.Auth, socket: socket},
        {ExMoQ.Relay, %ExMoQ.Relay{auth: {:url, ExMoQ.Relay.Auth.url(socket)}, tcp: :auto}}
      ]

  `ExMoQ.Relay.Auth.Plug` is the HTTP adapter when the server is not started
  by this module.
  """

  alias ExMoQ.Relay.Auth.{Grant, Request}

  @doc """
  The grant for one of the relay's requests.

  Return `{:grant, grant}` to admit (2xx), `:refuse` to close the session
  (403), or `:ok` to acknowledge an `:end` with an empty body.
  """
  @callback admit(Request.t()) :: {:grant, Grant.t()} | :refuse | :ok

  @doc """
  A unique Unix socket path under the system temp directory, for `socket:`
  and `url/1`.
  """
  @spec socket_path() :: Path.t()
  def socket_path do
    name = "ex-moq-relay-auth-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    Path.join(System.tmp_dir!(), name)
  end

  @doc "The `auth: {:url, _}` value for a Unix socket path."
  @spec url(Path.t()) :: String.t()
  def url(socket) when is_binary(socket), do: "unix://" <> socket

  @doc """
  Child spec for an HTTP server on a Unix socket that answers with `module`.

  Options: `:module` (required), `:socket` (default `socket_path/0`), `:name`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.validate!(opts, [:module, :socket, :name])
    module = Keyword.fetch!(opts, :module)
    name = Keyword.get(opts, :name)

    %{
      id: name || {__MODULE__, module},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts the auth HTTP server; see `child_spec/1`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:module, :socket, :name])
    module = Keyword.fetch!(opts, :module)
    socket = Keyword.get_lazy(opts, :socket, &socket_path/0)
    _ = File.rm(socket)

    Bandit.start_link(
      plug: {ExMoQ.Relay.Auth.Plug, module},
      ip: {:local, socket},
      port: 0,
      startup_log: false
    )
  end
end
