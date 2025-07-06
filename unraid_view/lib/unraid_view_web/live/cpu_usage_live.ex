defmodule UnraidViewWeb.CpuUsageLive do
  @moduledoc """
  LiveView component that displays real-time CPU usage using a daisyUI radial
  progress indicator. The usage value is refreshed every second by polling the
  Erlang `:cpu_sup` module (part of `:os_mon`).
  """
  use Phoenix.LiveView

  @max_history 300
  @default_window 60

  # Public API --------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: UnraidView.Monitoring.CPU.subscribe()

    cores = UnraidView.Monitoring.CPU.per_core_usage()
    util = UnraidView.Monitoring.CPU.average_util(cores)
    history = [util]

    {:ok,
     socket
     |> assign(
       cpu_per_core: cores,
       cpu_util: util,
       history: history,
       history_json: Jason.encode!(history),
       window: @default_window,
       show_chart: true,
       max_history: @max_history
     )}
  end

  @impl true
  def handle_info({:cpu_usage, %{per_core: cores, util: util}}, socket) do
    history =
      [util | socket.assigns.history]
      |> Enum.take(@max_history)

    {:noreply,
     socket
     |> assign(:cpu_per_core, cores)
     |> assign(:cpu_util, util)
     |> assign(:history, history)
     |> assign(:history_json, Jason.encode!(history))
     |> push_event("cpu_usage_tick", %{value: util})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    # No-op: legacy timer message before code reload
    {:noreply, socket}
  end

  @impl true
  def handle_info({:set_show_chart, show?}, socket) when is_boolean(show?) do
    require Logger
    Logger.info("CpuUsageLive received :set_show_chart #{inspect(show?)}")
    {:noreply,
     socket
     |> assign(:show_chart, show?)
     |> push_event("chart_toggle", %{show: show?})}
  end

  @impl true
  def handle_event("set_window", %{"window" => window_str}, socket) do
    window = String.to_integer(window_str)

    {:noreply,
     socket |> assign(:window, window) |> push_event("window_change", %{window: window})}
  end

  @impl true
  def handle_event("set_show_chart", %{"show" => show}, socket) do
    show_bool = if is_boolean(show), do: show, else: show == "true"
    {:noreply, assign(socket, :show_chart, show_bool)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl card-border border-primary">
      <div class="card-body">
        <h2 class="card-title text-sm">CPU Usage</h2>
        <button id="btn-toggle-chart" class="btn btn-xs ml-auto" phx-hook="ChartToggle" data-container-id="cpu-chart-container" data-initial-show={@show_chart}>
          <%= if @show_chart, do: "Hide Chart", else: "Show Chart" %>
        </button>

        <div class="flex items-center gap-2 mb-2">
          <form phx-change="set_window" class="flex items-center gap-2">
            <label class="text-xs" for="window-select">Window:</label>
            <select id="window-select" name="window" class="select select-xs">
              <option value="10" selected={@window == 10}>10s</option>
              <option value="30" selected={@window == 30}>30s</option>
              <option value="60" selected={@window == 60}>1m</option>
              <option value="120" selected={@window == 120}>2m</option>
              <option value="300" selected={@window == 300}>5m</option>
            </select>
          </form>
        </div>

        <div id="cpu-chart-container" class="w-full h-32" phx-hook="CpuChart" phx-update="ignore" data-history={@history_json} data-window={@window} data-max-history={@max_history} style={"display: #{if @show_chart, do: "block", else: "none"};"}>
          <canvas id="cpu-chart" class="w-full h-full"></canvas>
        </div>

        <div class="flex items-center gap-4 mt-4">
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

  # Internal helpers were moved to `UnraidView.Monitoring.CPU`.
end
