defmodule UnraidWeb.LogMonitorDemoLive do
  @moduledoc """
  Demo LiveView for the new LogMonitorServer-based log viewing.

  Demonstrates:
  - Real-time log tailing with byte offsets
  - Multiple segments (log rotation)
  - Independent scroll windows per segment using EmbeddedLogMonitorLive
  """
  use UnraidWeb, :live_view

  @base_log_path "tmp/monitor_demo.log"

  def mount(_params, _session, socket) do
    log_path = Path.expand(@base_log_path)
    File.mkdir_p!(Path.dirname(log_path))

    # Create initial log file if it doesn't exist
    unless File.exists?(log_path) do
      File.write!(log_path, "Log started at #{DateTime.utc_now()}\n")
    end

    # Discover all segments
    segments = discover_segments(log_path)

    socket =
      socket
      |> assign(:base_path, log_path)
      |> assign(:segments, segments)
      |> assign(:lines_to_add, 10)
      |> assign(:target_segment, log_path)
      |> assign(:collapsed, MapSet.new())
      |> assign(:page_title, "Log Monitor Demo")

    {:ok, socket}
  end

  defp discover_segments(base_path) do
    dir = Path.dirname(base_path)
    base = Path.basename(base_path)

    # Find rotated files (demo.log.1, demo.log.2, etc.)
    rotated =
      if File.dir?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(fn f -> String.starts_with?(f, base <> ".") end)
        |> Enum.map(fn f ->
          suffix = String.replace_prefix(f, base <> ".", "")
          case Integer.parse(suffix) do
            {n, ""} -> {Path.join(dir, f), n, "#{base}.#{n}"}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_path, n, _label} -> n end, :desc)
        |> Enum.map(fn {path, _n, label} -> %{path: path, label: label} end)
      else
        []
      end

    # Current file last (most recent)
    current = %{path: base_path, label: "#{base} (current)"}
    rotated ++ [current]
  end

  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <h1 class="text-2xl font-bold">Log Monitor Demo - Segmented</h1>
      <p class="text-sm opacity-70">Multiple log segments with independent scroll windows</p>

      <div class="flex flex-wrap items-center gap-2">
        <form phx-change="update_settings" class="flex items-center gap-2">
          <div class="join">
            <input
              type="number"
              min="1"
              max="1000"
              value={@lines_to_add}
              name="count"
              class="input input-bordered input-sm join-item w-20"
            />
            <select name="target" class="select select-bordered select-sm join-item">
              <option :for={seg <- @segments} value={seg.path} selected={seg.path == @target_segment}>
                {seg.label}
              </option>
            </select>
            <button type="button" phx-click="add_log" class="btn btn-primary btn-sm join-item">
              Add {@lines_to_add} Line{if @lines_to_add != 1, do: "s"}
            </button>
          </div>
        </form>
        <button phx-click="rotate_log" class="btn btn-warning btn-sm">Rotate Log</button>
        <button phx-click="clear_all" class="btn btn-error btn-sm">Clear All</button>
      </div>

      <div class="card bg-base-200 p-4">
        <h3 class="font-semibold mb-2">Segments ({length(@segments)})</h3>
        <div class="text-sm space-y-1 font-mono">
          <div :for={seg <- @segments} class="flex items-center gap-2">
            <span class={if seg.path == @target_segment, do: "text-primary font-bold", else: "opacity-70"}>
              {seg.label}
            </span>
            <span :if={MapSet.member?(@collapsed, seg.path)} class="badge badge-ghost badge-sm">collapsed</span>
          </div>
        </div>
      </div>

      <div class="space-y-4">
        <div :for={seg <- @segments} class="card bg-base-100 border border-base-300 overflow-hidden">
          <div
            class="text-sm px-4 py-2 bg-base-200 cursor-pointer flex justify-between items-center"
            phx-click="toggle_segment"
            phx-value-path={seg.path}
          >
            <span class="font-mono font-semibold">{seg.label}</span>
            <span class="text-xs opacity-50">{if MapSet.member?(@collapsed, seg.path), do: "▶", else: "▼"}</span>
          </div>
          <div class={if MapSet.member?(@collapsed, seg.path), do: "hidden"}>
            <%= if File.exists?(seg.path) do %>
              <%= live_render(@socket, UnraidWeb.EmbeddedLogMonitorLive,
                id: "log-#{segment_id(seg.path)}",
                session: %{
                  "path" => seg.path,
                  "label" => seg.label,
                  "height" => "16rem",
                  "initial_lines" => 200
                }
              ) %>
            <% else %>
              <div class="p-4 text-sm opacity-50">File not found</div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp segment_id(path) do
    path
    |> String.replace(~r/[^a-zA-Z0-9]/, "-")
    |> String.trim_leading("-")
  end

  def handle_event("update_settings", params, socket) do
    socket =
      socket
      |> maybe_update_count(params["count"])
      |> maybe_update_target(params["target"])

    {:noreply, socket}
  end

  def handle_event("add_log", _, socket) do
    path = socket.assigns.target_segment
    count = socket.assigns.lines_to_add

    # Create file if it doesn't exist (for rotated segments)
    unless File.exists?(path) do
      File.write!(path, "")
    end

    lines =
      1..count
      |> Enum.map(fn i -> "[#{Path.basename(path)}] Entry ##{i} at #{DateTime.utc_now()}\n" end)
      |> Enum.join()

    File.write!(path, lines, [:append])
    {:noreply, socket}
  end

  def handle_event("rotate_log", _, socket) do
    base_path = socket.assigns.base_path

    # Shift existing rotated files up
    shift_rotated_files(base_path)

    # Move current to .1
    if File.exists?(base_path) do
      File.rename!(base_path, base_path <> ".1")
    end

    # Create new current file
    File.write!(base_path, "=== Log rotated at #{DateTime.utc_now()} ===\n")

    # Re-discover segments
    segments = discover_segments(base_path)

    socket =
      socket
      |> assign(:segments, segments)
      |> assign(:target_segment, base_path)

    {:noreply, socket}
  end

  def handle_event("clear_all", _, socket) do
    base_path = socket.assigns.base_path
    dir = Path.dirname(base_path)
    base = Path.basename(base_path)

    # Delete all log files
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn f -> f == base || String.starts_with?(f, base <> ".") end)
      |> Enum.each(fn f -> File.rm!(Path.join(dir, f)) end)
    end

    # Create fresh log file
    File.write!(base_path, "=== Log started at #{DateTime.utc_now()} ===\n")

    # Re-discover segments
    segments = discover_segments(base_path)

    socket =
      socket
      |> assign(:segments, segments)
      |> assign(:target_segment, base_path)
      |> assign(:collapsed, MapSet.new())

    {:noreply, socket}
  end

  def handle_event("toggle_segment", %{"path" => path}, socket) do
    collapsed =
      if MapSet.member?(socket.assigns.collapsed, path) do
        MapSet.delete(socket.assigns.collapsed, path)
      else
        MapSet.put(socket.assigns.collapsed, path)
      end

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  defp maybe_update_count(socket, nil), do: socket

  defp maybe_update_count(socket, count) do
    count = String.to_integer(count) |> max(1) |> min(1000)
    assign(socket, :lines_to_add, count)
  end

  defp maybe_update_target(socket, nil), do: socket
  defp maybe_update_target(socket, target), do: assign(socket, :target_segment, target)

  defp shift_rotated_files(base_path) do
    dir = Path.dirname(base_path)
    base = Path.basename(base_path)

    existing =
      if File.dir?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(fn f -> String.starts_with?(f, base <> ".") end)
        |> Enum.map(fn f ->
          suffix = String.replace_prefix(f, base <> ".", "")
          case Integer.parse(suffix) do
            {n, ""} -> {Path.join(dir, f), n}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_path, n} -> n end, :desc)
      else
        []
      end

    # Shift each file up by 1 (highest first)
    Enum.each(existing, fn {old_path, n} ->
      new_path = "#{base_path}.#{n + 1}"
      File.rename!(old_path, new_path)
    end)
  end

  # Handle notifications from child log monitors (optional)
  def handle_info({:log_monitor_started, _id, _path, _pid}, socket) do
    {:noreply, socket}
  end

  def handle_info({:log_monitor_reset, _id, _path}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
