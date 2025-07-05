defmodule UnraidViewWeb.CpuUsageLive do
  @moduledoc """
  LiveView component that displays real-time CPU usage using a daisyUI radial
  progress indicator. The usage value is refreshed every second by polling the
  Erlang `:cpu_sup` module (part of `:os_mon`).
  """
  use Phoenix.LiveView

  @refresh_interval 1_000

  # Public API --------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_interval, :refresh)

    cores = per_core_usage()
    {:ok,
     socket
     |> assign(:cpu_per_core, cores)
     |> assign(:cpu_util, average_util(cores))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    cores = per_core_usage()
    {:noreply,
     socket
     |> assign(:cpu_per_core, cores)
     |> assign(:cpu_util, average_util(cores))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl card-border border-primary">
      <div class="card-body">
        <h2 class="card-title text-sm">CPU Usage</h2>
        <div class="flex items-center gap-4">
          <div class="flex-1">
            <div class="w-full bg-base-300 rounded-full h-3">
              <div
                class="bg-primary h-3 rounded-full transition-all duration-300 ease-in-out"
                style={"width: #{@cpu_util}%"}
              ></div>
            </div>
          </div>
          <span class="text-lg font-semibold min-w-[3rem] text-right">
            {Float.round(@cpu_util, 1)}%
          </span>
        </div>
        <div class="flex flex-col gap-2 mt-4">
          <%= for {util, idx} <- Enum.with_index(@cpu_per_core) do %>
            <div class="flex items-center gap-2">
              <span class="text-xs font-medium w-14">Core <%= idx %></span>
              <div class="flex-1">
                <div class="w-full bg-base-300 rounded-full h-2">
                  <div
                    class="bg-secondary h-2 rounded-full transition-all duration-300 ease-in-out"
                    style={"width: #{util}%"}
                  ></div>
                </div>
              </div>
              <span class="text-xs font-medium min-w-[3rem] text-right">
                <%= Float.round(util, 1) %>%
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Helpers -----------------------------------------------------------------

  defp cpu_usage do
    # Deprecated: kept for compatibility but no longer used.
    average_util(per_core_usage())
  end

  defp per_core_usage do
    case :cpu_sup.util([:per_cpu]) do
      list when is_list(list) ->
        Enum.map(list, fn
          {_, busy, _nonbusy, _misc} when is_number(busy) -> busy
          {_, busy_states, _nonbusy, _misc} when is_list(busy_states) ->
            # Sum busy states if detailed option is returned unexpectedly
            Enum.reduce(busy_states, 0.0, fn {_, val}, acc -> acc + val end)
          _ -> 0.0
        end)

      _ -> []
    end
  end

  defp average_util([]), do: 0.0
  defp average_util(list), do: Enum.sum(list) / length(list)
end
