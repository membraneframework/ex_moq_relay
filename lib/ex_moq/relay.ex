defmodule ExMoQ.Relay do
  @moduledoc """
  Runs a [moq-relay](https://doc.moq.dev/bin/relay) binary as a supervised OS
  process. Requires moq-relay 0.15.0 or later.

  Ports are chosen before the relay starts, so a config is all it takes to
  reach the relay:

      config = ExMoQ.Relay.Config.new!(tcp: :auto, web: :auto)
      {:ok, relay} = ExMoQ.Relay.start_link(config)
      ExMoQ.Relay.tcp_url(config)     #=> "tcp://127.0.0.1:54321"
      ExMoQ.Relay.quic_url(config)    #=> "https://127.0.0.1:54322"
      ExMoQ.Relay.web_url(config)     #=> "http://127.0.0.1:54323"

  `start_link/1` returns once the relay accepts connections. The returned
  process owns the relay: the relay stops with it, and it exits with
  `{:exit_status, status}` when the relay exits with a non-zero status.

  Under a supervisor, whose `:restart` setting decides what happens when the
  relay exits:

      {ExMoQ.Relay, ExMoQ.Relay.Config.new!(quic: 4443, web: 4443, name: MyApp.Relay)}

  The options are documented in `ExMoQ.Relay.Config`.
  """

  alias ExMoQ.Relay.Config

  @probe_interval_ms 100

  @typedoc """
  Why the relay did not start: no binary, it exited (with the reason its
  process exited with), or it did not accept connections within the given
  milliseconds.
  """
  @type start_error ::
          :no_binary
          | {:exited, reason :: term()}
          | {:not_ready, timeout_ms :: non_neg_integer()}

  @typedoc "Why `version/1` could not read the relay's version."
  @type version_error ::
          :no_binary
          | {:exit_status, integer(), output :: String.t()}
          | {:unexpected_output, term()}

  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, type: :worker}
  end

  @doc """
  Starts a relay linked to the caller and blocks until it accepts
  connections.

  If the relay exits before it is ready, a caller that does not trap exits
  exits with it, as with `GenServer.start_link/3`.
  """
  @spec start_link(Config.t()) ::
          {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  def start_link(%Config{} = config) do
    args = args(config)

    case find_binary(config.binary) do
      nil -> {:error, :no_binary}
      binary -> start_daemon(binary, args, config)
    end
  end

  @doc """
  Resolves the relay binary:
  1. `binary` argument
  2. `$MOQ_RELAY`
  3. `moq-relay` on `$PATH`;
  4. `nil` when none is an executable.
  """
  @spec find_binary(Path.t() | nil) :: Path.t() | nil
  def find_binary(binary \\ nil) do
    System.find_executable(binary || System.get_env("MOQ_RELAY") || "moq-relay")
  end

  @doc "The version the binary reports."
  @spec version(Path.t() | nil) :: {:ok, String.t()} | {:error, version_error()}
  def version(binary \\ find_binary()) do
    with path when is_binary(path) <- binary || {:error, :no_binary},
         {out, 0} <- System.cmd(path, ["--help"], stderr_to_stdout: true),
         [line | _rest] <- String.split(out, "\n"),
         ["moq-relay", version] <- String.split(String.trim(line), " ", parts: 2) do
      {:ok, version}
    else
      {:error, _reason} = error -> error
      {out, status} when is_integer(status) -> {:error, {:exit_status, status, out}}
      other -> {:error, {:unexpected_output, other}}
    end
  end

  @doc """
  The relay's command line. Exposed so a caller can see or test what will be
  run.
  """
  @spec args(Config.t()) :: [String.t()]
  def args(%Config{} = config) do
    listen = fn
      _flag, nil -> []
      flag, port -> [flag, address(config.ip, port)]
    end

    auth =
      case config.auth_public do
        nil -> []
        list when is_list(list) -> ["--auth-public", Enum.join(list, ",")]
        string -> ["--auth-public", string]
      end

    tls =
      case config.quic do
        {_port, tls_generate: host} when host != nil -> ["--listen-tls-generate", host]
        _no_certificate -> []
      end

    ["--log-level", config.log_level] ++
      listen.("--listen", quic_port(config)) ++
      listen.("--listen-tcp-bind", config.tcp) ++
      listen.("--web-http-listen", config.web) ++
      listen.("--internal-listen", config.internal) ++
      tls ++
      auth ++
      config.args
  end

  @doc "`https://host:port` of the QUIC listener, or `nil`; append the path yourself."
  @spec quic_url(Config.t()) :: String.t() | nil
  def quic_url(%Config{} = config), do: url(config, "https", quic_port(config))

  @doc "`tcp://host:port` of the plaintext TCP listener, or `nil`."
  @spec tcp_url(Config.t()) :: String.t() | nil
  def tcp_url(%Config{} = config), do: url(config, "tcp", config.tcp)

  @doc """
  `http://host:port` of the web listener (`/health`, `/certificate.sha256`,
  `/fetch`), or `nil`.
  """
  @spec web_url(Config.t()) :: String.t() | nil
  def web_url(%Config{} = config), do: url(config, "http", config.web)

  @doc "`http://host:port` of the internal listener (`/health`, `/metrics`), or `nil`."
  @spec internal_url(Config.t()) :: String.t() | nil
  def internal_url(%Config{} = config), do: url(config, "http", config.internal)

  @doc "Stops the relay."
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(relay, timeout \\ 5_000), do: GenServer.stop(relay, :normal, timeout)

  ## Starting

  @spec start_daemon(Path.t(), [String.t()], Config.t()) ::
          {:ok, pid()} | {:error, start_error() | {:already_started, pid()}}
  defp start_daemon(binary, args, config) do
    with {:ok, daemon} <- MuonTrap.Daemon.start_link(binary, args, daemon_opts(config)) do
      ref = Process.monitor(daemon)
      deadline = System.monotonic_time(:millisecond) + config.ready_timeout

      case await_ready(config, ready_port(config), ref, deadline) do
        :ok ->
          Process.demonitor(ref, [:flush])
          {:ok, daemon}

        {:error, {:not_ready, _timeout_ms}} = error ->
          Process.demonitor(ref, [:flush])
          stop(daemon)
          error

        {:error, {:exited, _reason}} = error ->
          error
      end
    end
  end

  @spec daemon_opts(Config.t()) :: keyword()
  defp daemon_opts(config) do
    output =
      case config do
        %Config{on_output: fun} when fun != nil -> [logger_fun: fun]
        %Config{log_output: nil} -> [logger_fun: fn _line -> :ok end]
        %Config{log_output: level} -> [log_output: level, log_prefix: "moq-relay: "]
      end

    name = if config.name, do: [name: config.name], else: []

    [stderr_to_stdout: true, exit_status_to_reason: &{:exit_status, &1}] ++ output ++ name
  end

  @spec ready_port(Config.t()) :: :inet.port_number() | nil
  defp ready_port(%Config{ready: :none}), do: nil
  defp ready_port(%Config{ready: listener} = config), do: Map.fetch!(config, listener)

  @spec await_ready(Config.t(), :inet.port_number() | nil, reference(), integer()) ::
          :ok | {:error, start_error()}
  defp await_ready(_config, nil, _ref, _deadline), do: :ok

  defp await_ready(config, port, ref, deadline) do
    receive do
      {:DOWN, ^ref, :process, _daemon, reason} -> {:error, {:exited, reason}}
    after
      @probe_interval_ms ->
        cond do
          probe(config.ip, port) ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            {:error, {:not_ready, config.ready_timeout}}

          true ->
            await_ready(config, port, ref, deadline)
        end
    end
  end

  @spec probe(:inet.ip_address(), :inet.port_number()) :: boolean()
  defp probe(ip, port) do
    host = reachable(ip)

    case :gen_tcp.connect(host, port, [:binary, active: false] ++ family(host), 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  ## Addresses

  @spec quic_port(Config.t()) :: :inet.port_number() | nil
  defp quic_port(%Config{quic: {port, _tls}}), do: port
  defp quic_port(%Config{quic: nil}), do: nil

  @spec url(Config.t(), String.t(), :inet.port_number() | nil) :: String.t() | nil
  defp url(_config, _scheme, nil), do: nil
  defp url(config, scheme, port), do: "#{scheme}://#{address(reachable(config.ip), port)}"

  @spec family(:inet.ip_address()) :: [:inet6]
  defp family(ip) when tuple_size(ip) == 8, do: [:inet6]
  defp family(_ip), do: []

  # Where a listener bound to `ip` is reached from this host.
  @spec reachable(:inet.ip_address()) :: :inet.ip_address()
  defp reachable({0, 0, 0, 0}), do: {127, 0, 0, 1}
  defp reachable({0, 0, 0, 0, 0, 0, 0, 0}), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp reachable(ip), do: ip

  @spec address(:inet.ip_address(), :inet.port_number()) :: String.t()
  defp address(ip, port) when tuple_size(ip) == 8 and is_integer(port),
    do: "[#{:inet.ntoa(ip)}]:#{port}"

  defp address(ip, port) when is_integer(port), do: "#{:inet.ntoa(ip)}:#{port}"
end
