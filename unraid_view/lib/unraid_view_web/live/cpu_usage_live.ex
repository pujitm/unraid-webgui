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

    {:ok, assign(socket, :cpu_util, cpu_usage())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :cpu_util, cpu_usage())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
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
      </div>
    </div>
    """
  end

  # Helpers -----------------------------------------------------------------

  defp cpu_usage do
    case :cpu_sup.util() do
      :undefined -> 0.0
      util when is_number(util) -> util
      _ -> 0.0
    end
  end
end
