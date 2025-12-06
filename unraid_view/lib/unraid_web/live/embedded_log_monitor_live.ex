defmodule UnraidWeb.EmbeddedLogMonitorLive do
  @moduledoc """
  Embeddable log monitor LiveView for use as a child in other LiveViews.

  This is a child LiveView that fully encapsulates log monitoring,
  receiving messages directly from LogMonitorServer and handling all
  log viewing events internally.

  ## Usage

      <%= live_render(@socket, UnraidWeb.EmbeddedLogMonitorLive,
        id: "syslog-monitor",
        session: %{
          "path" => "/var/log/syslog",
          "initial_lines" => 200,
          "height" => "20rem"
        }
      ) %>

  ## Session Options

    * `"path"` - Required. Path to the log file to monitor.
    * `"initial_lines"` - Optional. Number of lines to load initially. Defaults to 200.
    * `"height"` - Optional. CSS height value. Defaults to "24rem".
    * `"label"` - Optional. Display label. Defaults to the filename.
    * `"parent_pid"` - Optional. PID to notify of events.

  ## Parent Notifications

  If `parent_pid` is provided, the following messages are sent:

    * `{:log_monitor_started, id, path, pid}` - When monitoring starts
    * `{:log_monitor_reset, id, path}` - When log is truncated/reset
  """

  use UnraidWeb, :live_view

  alias Unraid.Log.LogMonitorServer

  @default_initial_lines 200
  @default_height "24rem"

  @impl true
  def mount(_params, session, socket) do
    path = session["path"] || raise "path is required"
    path = Path.expand(path)

    socket =
      socket
      |> assign(:monitor_id, socket.id)
      |> assign(:path, path)
      |> assign(:label, session["label"] || Path.basename(path))
      |> assign(:initial_lines, session["initial_lines"] || @default_initial_lines)
      |> assign(:height, session["height"] || @default_height)
      |> assign(:parent_pid, session["parent_pid"])
      |> assign(:earliest_offset, 0)
      |> assign(:line_count, 0)
      |> assign(:auto_scroll, true)
      |> assign(:error, nil)
      |> stream_configure(:log_lines, dom_id: &"log-line-#{&1.offset}")
      |> stream(:log_lines, [])

    if connected?(socket) do
      send(self(), :subscribe)
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col border border-base-300 rounded-box overflow-hidden bg-base-100" style={"height: #{@height}"}>
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-2 bg-base-200 border-b border-base-300">
        <div class="flex items-center gap-2 text-sm font-mono">
          <span class="opacity-70">Log:</span>
          <span class="font-bold truncate max-w-md" title={@path}>{@label}</span>
          <span class="badge badge-sm">{@line_count} lines</span>
        </div>

        <div class="flex items-center gap-2">
          <div class="tooltip tooltip-bottom" data-tip="Toggle Auto-scroll">
            <label class="swap swap-rotate btn btn-ghost btn-xs">
              <input
                type="checkbox"
                checked={@auto_scroll}
                phx-click="toggle_auto_scroll"
              />
              <div class="swap-on flex items-center gap-1 text-primary">
                <.icon name="hero-arrow-down-circle" class="w-4 h-4" />
                <span class="text-xs">Auto-scroll</span>
              </div>
              <div class="swap-off flex items-center gap-1 opacity-50">
                <.icon name="hero-pause-circle" class="w-4 h-4" />
                <span class="text-xs">Paused</span>
              </div>
            </label>
          </div>
        </div>
      </div>

      <%!-- Error state --%>
      <div :if={@error} class="flex-1 flex items-center justify-center">
        <div class="alert alert-error max-w-md">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error}</span>
        </div>
      </div>

      <%!-- Log content --%>
      <div
        :if={!@error}
        id={"#{@monitor_id}-scroll-container"}
        class="flex-1 overflow-y-auto font-mono text-xs p-4 space-y-0.5 bg-base-100"
        phx-hook="LogViewerScroll"
        phx-update="stream"
        data-auto-scroll={to_string(@auto_scroll)}
      >
        <div
          :for={{dom_id, item} <- @streams.log_lines}
          id={dom_id}
          class="whitespace-pre-wrap break-all hover:bg-base-200/50 px-1 -mx-1 rounded"
          data-offset={item.offset}
        >
          {item.text}
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Handle Info - Subscription and Log Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:subscribe, socket) do
    path = socket.assigns.path

    if File.exists?(path) do
      case LogMonitorServer.subscribe(path, initial_lines: socket.assigns.initial_lines) do
        {:ok, _pid, lines} ->
          items = lines_to_stream_items(lines)

          earliest =
            case lines do
              [] -> 0
              [first | _] -> first.offset
            end

          notify_parent(socket, {:log_monitor_started, socket.assigns.monitor_id, path, self()})

          socket =
            socket
            |> assign(:earliest_offset, earliest)
            |> assign(:line_count, length(lines))
            |> stream(:log_lines, items)
            |> push_event("log_viewer:scroll_to_bottom", %{id: socket.assigns.monitor_id})

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :error, "Failed to subscribe: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :error, "File not found: #{path}")}
    end
  end

  # New log lines from LogMonitorServer
  @impl true
  def handle_info({:log_lines, path, lines}, socket) do
    if path == socket.assigns.path do
      items = lines_to_stream_items(lines)

      socket =
        socket
        |> assign(:line_count, socket.assigns.line_count + length(lines))
        |> stream(:log_lines, items)

      socket =
        if socket.assigns.auto_scroll do
          push_event(socket, "log_viewer:scroll_to_bottom", %{id: socket.assigns.monitor_id})
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Log reset (truncation)
  @impl true
  def handle_info({:log_reset, path}, socket) do
    if path == socket.assigns.path do
      notify_parent(socket, {:log_monitor_reset, socket.assigns.monitor_id, path})

      socket =
        socket
        |> assign(:earliest_offset, 0)
        |> assign(:line_count, 0)
        |> stream(:log_lines, [], reset: true)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Handle Event - From JavaScript Hook
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_auto_scroll", params, socket) do
    new_state =
      case params["value"] do
        # JS hook sends explicit boolean
        val when val in [true, "true"] -> true
        val when val in [false, "false"] -> false
        # Checkbox sends "on" when checked, nil/missing when unchecked
        "on" -> true
        # Default: toggle current state
        _ -> !socket.assigns.auto_scroll
      end

    socket = assign(socket, :auto_scroll, new_state)

    socket =
      if new_state do
        push_event(socket, "log_viewer:scroll_to_bottom", %{id: socket.assigns.monitor_id})
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_history", _params, socket) do
    current_offset = socket.assigns.earliest_offset

    if current_offset > 0 do
      {lines, new_earliest} = LogMonitorServer.load_history(socket.assigns.path, current_offset, 100)

      if lines != [] do
        # Reverse items so they prepend in correct chronological order.
        # When stream/4 inserts at: 0, each item is inserted at position 0,
        # so [A, B, C] becomes [C, B, A]. Reversing first gives correct order.
        items = lines |> lines_to_stream_items() |> Enum.reverse()

        socket =
          socket
          |> assign(:earliest_offset, new_earliest)
          |> assign(:line_count, socket.assigns.line_count + length(lines))
          |> stream(:log_lines, items, at: 0)

        {:noreply, push_event(socket, "log_viewer:history_loaded", %{count: length(items)})}
      else
        {:noreply, push_event(socket, "log_viewer:history_loaded", %{count: 0})}
      end
    else
      {:noreply, push_event(socket, "log_viewer:history_loaded", %{count: 0})}
    end
  end

  # ---------------------------------------------------------------------------
  # Terminate - Cleanup
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:path] do
      LogMonitorServer.unsubscribe(socket.assigns.path)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp lines_to_stream_items(lines) do
    Enum.map(lines, fn %{offset: offset, text: text} ->
      %{offset: offset, text: text}
    end)
  end

  defp notify_parent(%{assigns: %{parent_pid: pid}}, msg) when is_pid(pid) do
    send(pid, msg)
  end

  defp notify_parent(_, _), do: :ok
end
