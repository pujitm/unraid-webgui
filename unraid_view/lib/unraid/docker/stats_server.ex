defmodule Unraid.Docker.StatsServer do
  @moduledoc """
  Polls container stats via `docker stats --no-stream` on demand.

  Only polls when there are active subscribers. Automatically stops
  when all subscribers disconnect.

  ## Stats Interval

  Polls every 5 seconds to reduce system load while keeping stats fresh.

  ## Output Format

  Each broadcast contains a list of stats maps:

      [
        %{id: "abc123", name: "nginx", cpu_percent: 5.2, memory_usage: "256MiB / 1GiB", memory_percent: 25.0},
        ...
      ]

  ## Usage

  Subscribers should call `request_stats/0` when mounting and
  `release_stats/0` when unmounting to manage demand.
  """

  use GenServer
  require Logger

  alias Unraid.Docker
  alias Unraid.Docker.Adapter

  @poll_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request stats polling. Call this when a LiveView mounts.
  Increments the subscriber count and starts polling if needed.
  """
  def request_stats do
    GenServer.call(__MODULE__, :request_stats)
  end

  @doc """
  Release stats polling. Call this when a LiveView unmounts.
  Decrements the subscriber count and stops polling if no subscribers remain.
  """
  def release_stats do
    GenServer.call(__MODULE__, :release_stats)
  end

  @impl true
  def init(_opts) do
    {:ok, %{subscriber_count: 0, timer_ref: nil}}
  end

  @impl true
  def handle_call(:request_stats, _from, state) do
    new_count = state.subscriber_count + 1
    Logger.debug("[StatsServer] Subscriber added, count: #{new_count}")

    state = %{state | subscriber_count: new_count}

    # Start polling if this is the first subscriber
    state =
      if new_count == 1 and is_nil(state.timer_ref) do
        # Poll immediately, then schedule recurring polls
        send(self(), :poll_stats)
        %{state | timer_ref: :polling}
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:release_stats, _from, state) do
    new_count = max(0, state.subscriber_count - 1)
    Logger.debug("[StatsServer] Subscriber removed, count: #{new_count}")

    state = %{state | subscriber_count: new_count}

    # Timer will stop naturally when poll_stats sees no subscribers
    state =
      if new_count == 0 do
        Logger.info("[StatsServer] Stopped polling (no subscribers)")
        %{state | timer_ref: nil}
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll_stats, state) do
    # Only poll if we have subscribers
    if state.subscriber_count > 0 do
      case Adapter.get_stats() do
        {:ok, stats} when stats != [] ->
          Docker.broadcast_stats(stats)

        {:ok, []} ->
          :ok

        {:error, reason} ->
          Logger.warning("[StatsServer] Failed to fetch stats: #{inspect(reason)}")
      end

      # Schedule next poll
      Process.send_after(self(), :poll_stats, @poll_interval_ms)
      {:noreply, state}
    else
      # No subscribers, don't reschedule
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
