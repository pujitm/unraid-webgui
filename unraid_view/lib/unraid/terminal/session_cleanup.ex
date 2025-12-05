defmodule Unraid.Terminal.SessionCleanup do
  @moduledoc """
  Periodic cleanup task for orphaned terminal sessions.

  Sessions are considered orphaned if they have no subscribers for longer
  than the configured threshold. Permanent sessions are never cleaned up.

  Runs every 5 minutes by default.
  """

  use GenServer
  require Logger

  alias Unraid.Terminal
  alias Unraid.Terminal.{TerminalSession, TerminalSupervisor}

  @cleanup_interval :timer.minutes(5)
  # 5 minutes with no subscribers before cleanup
  @orphan_threshold_seconds 300

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_orphaned_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_orphaned_sessions do
    now = System.monotonic_time(:second)

    TerminalSupervisor.list_sessions()
    |> Enum.each(fn session_id ->
      case TerminalSession.get_info(session_id) do
        {:ok, info} ->
          orphaned = info.subscriber_count == 0
          stale = now - info.last_activity > @orphan_threshold_seconds

          if orphaned && stale && !info.permanent do
            Logger.info("[SessionCleanup] Cleaning up orphaned session #{session_id}")
            Terminal.close(session_id)
          end

        {:error, _} ->
          # Session already gone
          :ok
      end
    end)
  end
end
