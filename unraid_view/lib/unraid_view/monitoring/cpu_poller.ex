defmodule UnraidView.Monitoring.CPUPoller do
  @moduledoc """
  Periodically samples CPU utilisation and broadcasts the measurements via
  `UnraidView.Monitoring.CPU.broadcast_usage/1`.
  """

  use GenServer

  alias UnraidView.Monitoring.CPU

  @refresh_interval 1_000

  # Client API ----------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Server callbacks ----------------------------------------------------------

  @impl true
  def init(:ok) do
    schedule_tick()
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    {cores, util} = CPU.snapshot()
    CPU.broadcast_usage(%{per_core: cores, util: util})
    schedule_tick()
    {:noreply, state}
  end

  # Helpers -------------------------------------------------------------------

  defp schedule_tick do
    Process.send_after(self(), :tick, @refresh_interval)
  end
end
