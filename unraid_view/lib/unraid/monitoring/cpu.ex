defmodule Unraid.Monitoring.CPU do
  @moduledoc """
  Context responsible for collecting and publishing CPU utilisation metrics.

  Exposes helper functions that can be consumed directly by the rest of the
  application *and* a PubSub-based API so UI components (e.g. LiveViews) can
  receive real-time updates without having to poll.
  """

  alias Phoenix.PubSub

  @topic "monitoring:cpu"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Subscribe the current process to CPU monitoring updates."
  def subscribe do
    PubSub.subscribe(Unraid.PubSub, @topic)
  end

  @doc "Broadcast a CPU usage update to all subscribers."
  def broadcast_usage(%{per_core: _cores, util: _util} = payload) do
    PubSub.broadcast(Unraid.PubSub, @topic, {:cpu_usage, payload})
  end

  @doc "Broadcast a request for LiveViews to show/hide the CPU chart."
  def set_show_chart(show?) when is_boolean(show?) do
    PubSub.broadcast(Unraid.PubSub, @topic, {:set_show_chart, show?})
  end

  @doc "Return utilisation (0-100 %) for every CPU core, using :cpu_sup."
  def per_core_usage do
    case :cpu_sup.util([:per_cpu]) do
      list when is_list(list) ->
        Enum.map(list, fn
          {_, busy, _nonbusy, _misc} when is_number(busy) ->
            busy

          {_, busy_states, _nonbusy, _misc} when is_list(busy_states) ->
            # Sum busy states if detailed option is returned unexpectedly
            Enum.reduce(busy_states, 0.0, fn {_, val}, acc -> acc + val end)

          _ ->
            0.0
        end)

      _ ->
        []
    end
  end

  @doc "Compute average utilisation across all cores (percentage)."
  def average_util([]), do: 0.0
  def average_util(list), do: Enum.sum(list) / length(list)

  @doc "Convenience helper: returns the pair {per_core, avg}."
  def snapshot do
    cores = per_core_usage()
    {cores, average_util(cores)}
  end
end
