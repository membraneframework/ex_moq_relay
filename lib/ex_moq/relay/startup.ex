defmodule ExMoQ.Relay.Startup do
  @moduledoc false
  # Starts the moq-relay OS process and waits until it reports readiness as
  # under systemd: `READY=1` on a unix datagram socket named in
  # `NOTIFY_SOCKET`. Called from `ExMoQ.Relay` init; the GenServer is the
  # mailbox for the socket, and stays linked to the daemon.

  require Logger

  alias ExMoQ.Relay.{Args, Options}

  @type t :: %{daemon: pid(), monitor: reference()}

  @type error_reason :: {:not_ready, timeout_ms :: non_neg_integer()} | {:exit_status, 0}

  @spec run(Path.t(), Options.t()) :: {:ok, t()} | {:error, error_reason()}
  def run(binary, %Options{} = options) do
    deadline = System.monotonic_time(:millisecond) + options.ready_timeout

    path =
      Path.join(System.tmp_dir!(), "moq-relay-#{System.pid()}-#{:rand.uniform(0xFFFFFFFF)}.sock")

    {:ok, socket} = :gen_udp.open(0, [:local, :binary, active: true, ifaddr: {:local, path}])

    {:ok, _pid} =
      Task.start(fn ->
        monitor = Port.monitor(socket)

        receive do
          {:DOWN, ^monitor, :port, ^socket, _reason} -> File.rm(path)
        end
      end)

    logger_fun =
      case options.log do
        :none -> fn _line -> :ok end
        {_level, fun} -> fun
        level -> fn line -> Logger.log(level, "moq-relay: " <> String.replace_invalid(line)) end
      end

    daemon_opts = [
      stderr_to_stdout: true,
      exit_status_to_reason: &{:exit_status, &1},
      logger_fun: logger_fun,
      # A `RUST_LOG` in the environment would override `--log-level`.
      env: [{"NOTIFY_SOCKET", path}, {"NO_COLOR", "1"}, {"RUST_LOG", nil}]
    ]

    {:ok, daemon} = MuonTrap.Daemon.start_link(binary, Args.args(options), daemon_opts)
    monitor = Process.monitor(daemon)

    result =
      case await_ready(socket, monitor, deadline) do
        :ok ->
          {:ok, %{daemon: daemon, monitor: monitor}}

        {:error, :not_ready} ->
          stop_daemon(daemon)
          {:error, {:not_ready, options.ready_timeout}}

        {:error, _exit_status} = error ->
          error
      end

    :ok = :gen_udp.close(socket)
    result
  end

  @spec await_ready(:gen_udp.socket(), reference(), integer()) ::
          :ok | {:error, :not_ready | {:exit_status, 0}}
  defp await_ready(socket, monitor, deadline) do
    receive do
      {:udp, ^socket, _address, _port, message} ->
        if "READY=1" in String.split(message, "\n"),
          do: :ok,
          else: await_ready(socket, monitor, deadline)

      # exit_status = 0 has to be mapped explicitly
      {:DOWN, ^monitor, :process, _daemon, :normal} ->
        {:error, {:exit_status, 0}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :not_ready}
    end
  end

  @spec stop_daemon(pid()) :: :ok
  defp stop_daemon(daemon) do
    GenServer.stop(daemon)
  catch
    :exit, _reason -> :ok
  end
end
