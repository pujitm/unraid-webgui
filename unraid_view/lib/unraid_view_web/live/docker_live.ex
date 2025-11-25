defmodule UnraidViewWeb.DockerLive do
  @moduledoc """
  Docker container management page.

  Displays all Docker containers with real-time stats streaming and
  provides actions for container lifecycle management.

  ## Features

    * Container list with status, network, ports, CPU, and memory
    * Real-time stats updates via streaming (no polling)
    * Instant state updates via Docker events
    * Bulk operations on selected containers
    * Slide-out logs panel
    * Filter by name and show/hide stopped containers

  ## Real-time Updates

  This LiveView uses two streaming sources:

    * `StatsStreamer` - Continuous CPU/memory stats via `docker stats`
    * `EventsStreamer` - Container lifecycle events via `docker events`

  Stats are pushed to the client using `rich-table:pulse` events for
  efficient DOM updates without full re-renders.
  """

  use UnraidViewWeb, :live_view

  alias UnraidView.Docker
  alias UnraidView.Docker.StatsStreamer
  alias UnraidView.Tree

  @table_id "docker-containers-table"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:table_id, @table_id)
      |> assign(:loading, true)
      |> assign(:containers, [])
      |> assign(:selected_ids, MapSet.new())
      |> assign(:stats_cache, %{})
      |> assign(:pending_actions, %{})
      |> assign(:filter, "")
      |> assign(:show_stopped, true)
      |> assign(:logs_panel_open, false)
      |> assign(:logs_container, nil)
      |> assign(:logs_content, [])
      |> assign(:dragging?, false)

    if connected?(socket) do
      Docker.subscribe()
      StatsStreamer.request_stats()
      send(self(), :load_containers)
    end

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    StatsStreamer.release_stats()
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Docker Containers</h1>
          <p class="text-sm text-base-content/60">
            Manage your Docker containers, view logs, and monitor resource usage.
          </p>
        </div>
        <div class="flex gap-2">
          <button
            class="btn btn-sm btn-ghost"
            phx-click="start_selected"
            disabled={MapSet.size(@selected_ids) == 0}
          >
            <.icon name="hero-play" class="w-4 h-4" /> Start
          </button>
          <button
            class="btn btn-sm btn-ghost"
            phx-click="stop_selected"
            disabled={MapSet.size(@selected_ids) == 0}
          >
            <.icon name="hero-stop" class="w-4 h-4" /> Stop
          </button>
          <button
            class="btn btn-sm btn-ghost"
            phx-click="restart_selected"
            disabled={MapSet.size(@selected_ids) == 0}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Restart
          </button>
        </div>
      </div>

      <div class="flex gap-6">
        <.logs_panel
          :if={@logs_panel_open}
          container={@logs_container}
          logs={@logs_content}
          on_close="close_logs"
        />

        <div class={["flex-1", @logs_panel_open && "max-w-[60%]"]}>
          <div class="flex items-center gap-4 mb-4">
            <input
              type="text"
              placeholder="Filter containers..."
              class="input input-bordered input-sm w-64"
              phx-change="filter_changed"
              phx-debounce="300"
              name="filter"
              value={@filter}
            />
            <label class="label cursor-pointer gap-2">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                checked={@show_stopped}
                phx-click="toggle_show_stopped"
              />
              <span class="label-text">Show stopped</span>
            </label>
            <span class="text-sm text-base-content/60">
              {container_count_label(@containers, @filter, @show_stopped)}
            </span>
          </div>

          <div :if={@loading} class="animate-pulse space-y-3">
            <div class="h-10 bg-base-300 rounded w-full"></div>
            <div :for={_ <- 1..5} class="h-14 bg-base-300 rounded w-full"></div>
          </div>

          <.rich_table
            :if={not @loading}
            id={@table_id}
            rows={filtered_containers(@containers, @filter, @show_stopped)}
            row_id={fn c -> c.id end}
            selectable={true}
            selected_row_ids={MapSet.to_list(@selected_ids)}
            selection_event="selection_changed"
            row_drop_event="docker:row_dropped"
            row_drag_event="docker:row_drag"
            phx-update="ignore"
          >
            <:col :let={slot} id="name" label="Container" width={260}>
              <div class="flex items-center gap-3 overflow-hidden">
                <div class="w-8 h-8 shrink-0 rounded bg-base-300 flex items-center justify-center overflow-hidden">
                  <img
                    :if={slot.row.icon}
                    src={slot.row.icon}
                    class="w-8 h-8 object-contain"
                    onerror="this.style.display='none'"
                  />
                  <.icon :if={!slot.row.icon} name="hero-cube" class="w-5 h-5 opacity-50" />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="font-semibold truncate" title={slot.row.name}>{slot.row.name}</div>
                  <div class="text-xs opacity-60 truncate" title={slot.row.image}>{slot.row.image}</div>
                </div>
              </div>
            </:col>

            <:col :let={slot} id="state" label="State" width={100}>
              <span
                class={["badge badge-sm", state_badge_class(slot.row.state)]}
                data-row-field="state"
                data-state={slot.row.state}
              >
                {state_label(slot.row.state)}
              </span>
            </:col>

            <:col :let={slot} id="network" label="Network" width={100}>
              <span class="text-sm truncate" data-row-field="network">{slot.row.network_mode}</span>
            </:col>

            <:col :let={slot} id="ip" label="IP" width={120}>
              <span class="text-sm font-mono" data-row-field="ip">{primary_ip(slot.row)}</span>
            </:col>

            <:col :let={slot} id="ports" label="Ports" width={140}>
              <span class="text-xs truncate" data-row-field="ports">{format_ports(slot.row.ports)}</span>
            </:col>

            <:col :let={slot} id="cpu" label="CPU" width={70}>
              <span class="text-sm font-mono" data-row-field="cpu">
                {format_cpu(slot.row.cpu_percent)}
              </span>
            </:col>

            <:col :let={slot} id="memory" label="Memory" width={110}>
              <span class="text-sm font-mono truncate" data-row-field="memory">
                {slot.row.memory_usage || "—"}
              </span>
            </:col>

            <:col :let={slot} id="uptime" label="Uptime" width={100}>
              <span class="text-sm truncate" data-row-field="uptime">{format_uptime(slot.row.status)}</span>
            </:col>

            <:action :let={slot}>
              <div class="dropdown dropdown-end" data-row-actions data-state={slot.row.state}>
                <label tabindex="0" class="btn btn-ghost btn-xs">
                  <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content menu p-2 shadow-lg bg-base-100 border border-base-300 rounded-box w-48"
                >
                  <li data-show-when="stopped">
                    <a phx-click={JS.push("start", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}>
                      <.icon name="hero-play" class="w-4 h-4" /> Start
                    </a>
                  </li>
                  <li data-show-when="running">
                    <a phx-click={JS.push("stop", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}>
                      <.icon name="hero-stop" class="w-4 h-4" /> Stop
                    </a>
                  </li>
                  <li data-show-when="running stopped">
                    <a phx-click={JS.push("restart", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}>
                      <.icon name="hero-arrow-path" class="w-4 h-4" /> Restart
                    </a>
                  </li>
                  <li data-show-when="running">
                    <a phx-click={JS.push("pause", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}>
                      <.icon name="hero-pause" class="w-4 h-4" /> Pause
                    </a>
                  </li>
                  <li data-show-when="paused">
                    <a phx-click={JS.push("resume", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}>
                      <.icon name="hero-play" class="w-4 h-4" /> Resume
                    </a>
                  </li>
                  <li class="divider"></li>
                  <li>
                    <a phx-click={JS.push("show_logs", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}>
                      <.icon name="hero-document-text" class="w-4 h-4" /> View Logs
                    </a>
                  </li>
                  <li :if={slot.row.web_ui}>
                    <a href={slot.row.web_ui} target="_blank" rel="noopener">
                      <.icon name="hero-globe-alt" class="w-4 h-4" /> WebUI
                    </a>
                  </li>
                  <li class="divider"></li>
                  <li>
                    <a
                      phx-click={JS.push("remove", value: %{id: slot.row.id}) |> JS.dispatch("click", to: "body")}
                      data-confirm={"Are you sure you want to remove #{slot.row.name}?"}
                      class="text-error"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" /> Remove
                    </a>
                  </li>
                </ul>
              </div>
            </:action>
          </.rich_table>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Logs Panel Component
  # ---------------------------------------------------------------------------

  attr :container, :map, required: true
  attr :logs, :list, required: true
  attr :on_close, :string, required: true

  defp logs_panel(assigns) do
    ~H"""
    <div class="card border border-base-300 bg-base-100 shadow-xl w-[500px] flex flex-col max-h-[80vh]">
      <div class="card-body p-4 flex flex-col h-full">
        <div class="flex items-center justify-between mb-2">
          <h3 class="font-semibold">
            Logs: {@container && @container.name}
          </h3>
          <button type="button" class="btn btn-ghost btn-xs" phx-click={@on_close}>
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
        <div class="flex-1 overflow-auto bg-base-300 rounded-lg p-3 font-mono text-xs">
          <pre class="whitespace-pre-wrap break-all">{Enum.join(@logs, "\n")}</pre>
        </div>
        <div class="mt-2 flex justify-end">
          <button type="button" class="btn btn-ghost btn-xs" phx-click="refresh_logs">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Refresh
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - Data Loading
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_containers, socket) do
    # Async load to keep mount fast
    pid = self()

    Task.start(fn ->
      containers = Docker.list_containers()
      send(pid, {:containers_loaded, containers})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:containers_loaded, containers}, socket) do
    # Merge with existing stats cache
    containers =
      Enum.map(containers, fn container ->
        case Map.get(socket.assigns.stats_cache, container.id) do
          nil -> container
          stats -> Docker.Container.with_stats(container, stats)
        end
      end)

    # Push full update for all containers (IP, ports, state, etc.)
    # This ensures dynamic fields update even with phx-update="ignore"
    diffs =
      Enum.map(containers, fn c ->
        %{
          id: c.id,
          state: c.state,
          state_label: state_label(c.state),
          state_class: state_badge_class(c.state),
          ip: primary_ip(c),
          ports: format_ports(c.ports),
          network: c.network_mode,
          uptime: format_uptime(c.status),
          cpu: format_cpu(c.cpu_percent),
          memory: c.memory_usage || "—",
          pending: Map.has_key?(socket.assigns.pending_actions, c.id)
        }
      end)

    socket =
      socket
      |> assign(loading: false, containers: containers)
      |> push_event("rich-table:pulse", %{target: @table_id, rows: diffs})

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - PubSub
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:stats_updated, stats}, socket) do
    # Skip stats updates while dragging to prevent DOM shifts
    if socket.assigns.dragging? do
      {:noreply, socket}
    else
      # Update stats cache
      stats_map = Map.new(stats, &{&1.id, &1})
      new_cache = Map.merge(socket.assigns.stats_cache, stats_map)

      # Push to client for DOM patching
      diffs =
        Enum.map(stats, fn s ->
          %{
            id: s.id,
            cpu: format_cpu(s.cpu_percent),
            memory: s.memory_usage
          }
        end)

      socket =
        socket
        |> assign(:stats_cache, new_cache)
        |> push_event("rich-table:pulse", %{target: @table_id, rows: diffs})

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:docker_event, %{action: action, container_id: container_id}}, socket)
      when action in ["start", "stop", "die", "pause", "unpause", "destroy", "create"] do
    # Clear pending action for this container
    pending = Map.delete(socket.assigns.pending_actions, container_id)

    # Map docker event action to container state
    new_state = action_to_state(action)

    # Update container in local state
    containers =
      Enum.map(socket.assigns.containers, fn c ->
        if c.id == container_id, do: %{c | state: new_state}, else: c
      end)

    # Push immediate status update to client
    socket =
      socket
      |> assign(:pending_actions, pending)
      |> assign(:containers, containers)
      |> push_event("rich-table:pulse", %{
        target: @table_id,
        rows: [
          %{
            id: container_id,
            state: new_state,
            state_label: state_label(new_state),
            state_class: state_badge_class(new_state),
            pending: false
          }
        ]
      })

    # Also refresh full container list for accurate data
    send(self(), :load_containers)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:containers_updated, containers}, socket) do
    {:noreply, assign(socket, containers: containers)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - User Actions
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("filter_changed", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: filter)}
  end

  @impl true
  def handle_event("toggle_show_stopped", _params, socket) do
    {:noreply, assign(socket, show_stopped: !socket.assigns.show_stopped)}
  end

  @impl true
  def handle_event("selection_changed", %{"selected_ids" => ids}, socket) do
    selected = ids |> List.wrap() |> MapSet.new()
    {:noreply, assign(socket, selected_ids: selected)}
  end

  # Single container actions
  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    {:noreply, start_container_action(socket, id, :starting, &Docker.start_container/1)}
  end

  @impl true
  def handle_event("stop", %{"id" => id}, socket) do
    {:noreply, start_container_action(socket, id, :stopping, &Docker.stop_container/1)}
  end

  @impl true
  def handle_event("restart", %{"id" => id}, socket) do
    {:noreply, start_container_action(socket, id, :restarting, &Docker.restart_container/1)}
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    {:noreply, start_container_action(socket, id, :pausing, &Docker.pause_container/1)}
  end

  @impl true
  def handle_event("resume", %{"id" => id}, socket) do
    {:noreply, start_container_action(socket, id, :resuming, &Docker.resume_container/1)}
  end

  defp start_container_action(socket, id, action_type, action_fn) do
    # Mark container as pending
    pending = Map.put(socket.assigns.pending_actions, id, action_type)

    # Push pending state to client immediately
    socket =
      socket
      |> assign(:pending_actions, pending)
      |> push_event("rich-table:pulse", %{
        target: @table_id,
        rows: [%{id: id, pending: true, pending_action: action_type}]
      })

    # Run action async
    Task.start(fn -> action_fn.(id) end)

    socket
  end

  @impl true
  def handle_event("remove", %{"id" => id}, socket) do
    Docker.remove_container(id)
    {:noreply, socket}
  end

  # Bulk actions
  @impl true
  def handle_event("start_selected", _params, socket) do
    Docker.start_all(MapSet.to_list(socket.assigns.selected_ids))
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_selected", _params, socket) do
    Docker.stop_all(MapSet.to_list(socket.assigns.selected_ids))
    {:noreply, socket}
  end

  @impl true
  def handle_event("restart_selected", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    Enum.each(ids, &Docker.restart_container/1)
    {:noreply, socket}
  end

  # Logs
  @impl true
  def handle_event("show_logs", %{"id" => id}, socket) do
    container = Enum.find(socket.assigns.containers, &(&1.id == id))
    logs = fetch_logs(id)

    {:noreply,
     socket
     |> assign(:logs_panel_open, true)
     |> assign(:logs_container, container)
     |> assign(:logs_content, logs)}
  end

  @impl true
  def handle_event("close_logs", _params, socket) do
    {:noreply, assign(socket, logs_panel_open: false)}
  end

  @impl true
  def handle_event("refresh_logs", _params, socket) do
    if socket.assigns.logs_container do
      logs = fetch_logs(socket.assigns.logs_container.id)
      {:noreply, assign(socket, logs_content: logs)}
    else
      {:noreply, socket}
    end
  end

  # RichTable events (no-op for now, could persist user preferences later)
  @impl true
  def handle_event("rich_table:column_resized", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("rich_table:column_reordered", _params, socket) do
    {:noreply, socket}
  end

  # Drag & drop reordering/nesting
  @impl true
  def handle_event("docker:row_drag", %{"state" => "start"}, socket) do
    {:noreply, assign(socket, :dragging?, true)}
  end

  def handle_event("docker:row_drag", %{"state" => "end"}, socket) do
    {:noreply, assign(socket, :dragging?, false)}
  end

  @impl true
  def handle_event("docker:row_dropped", params, socket) do
    case Tree.apply_drop(socket.assigns.containers, params) do
      {:ok, updated_containers} ->
        # Update selection to only include valid container IDs
        valid_ids = Tree.collect_ids(updated_containers)

        selected =
          socket.assigns.selected_ids
          |> MapSet.intersection(MapSet.new(valid_ids))

        {:noreply,
         socket
         |> assign(:containers, updated_containers)
         |> assign(:selected_ids, selected)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp fetch_logs(container_id) do
    case Docker.get_logs(container_id, tail: 200) do
      logs when is_list(logs) -> logs
      _ -> ["Failed to fetch logs"]
    end
  end

  defp filtered_containers(containers, filter, show_stopped) do
    containers
    |> Enum.filter(fn c ->
      (show_stopped || c.state != :stopped) &&
        (filter == "" ||
           String.contains?(String.downcase(c.name), String.downcase(filter)))
    end)
  end

  defp container_count_label(containers, filter, show_stopped) do
    filtered = filtered_containers(containers, filter, show_stopped)
    total = length(containers)
    shown = length(filtered)

    if shown == total do
      "#{total} containers"
    else
      "#{shown} of #{total} containers"
    end
  end

  defp state_badge_class(:running), do: "badge-success"
  defp state_badge_class(:paused), do: "badge-warning"
  defp state_badge_class(:stopped), do: "badge-error"
  defp state_badge_class(:restarting), do: "badge-info"
  defp state_badge_class(:created), do: "badge-ghost"
  defp state_badge_class(_), do: "badge-ghost"

  defp state_label(:running), do: "Running"
  defp state_label(:paused), do: "Paused"
  defp state_label(:stopped), do: "Stopped"
  defp state_label(:restarting), do: "Restarting"
  defp state_label(:created), do: "Created"
  defp state_label(:dead), do: "Dead"
  defp state_label(_), do: "Unknown"

  # Map docker event actions to container states
  defp action_to_state("start"), do: :running
  defp action_to_state("stop"), do: :stopped
  defp action_to_state("die"), do: :stopped
  defp action_to_state("pause"), do: :paused
  defp action_to_state("unpause"), do: :running
  defp action_to_state("create"), do: :created
  defp action_to_state("destroy"), do: :stopped
  defp action_to_state(_), do: :stopped

  defp primary_ip(%{networks: networks}) when map_size(networks) > 0 do
    networks
    |> Map.values()
    |> List.first()
    |> Map.get(:ip, "—")
    |> case do
      "" -> "—"
      ip -> ip
    end
  end

  defp primary_ip(_), do: "—"

  defp format_ports([]), do: "—"

  defp format_ports(ports) do
    ports
    |> Enum.filter(& &1.public)
    |> Enum.take(3)
    |> Enum.map(fn p -> "#{p.public}:#{p.private}" end)
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      result -> result
    end
  end

  defp format_cpu(nil), do: "—"
  defp format_cpu(cpu) when is_number(cpu), do: "#{Float.round(cpu * 1.0, 1)}%"
  defp format_cpu(cpu) when is_binary(cpu), do: cpu
  defp format_cpu(_), do: "—"

  defp format_uptime(nil), do: "—"
  defp format_uptime(""), do: "—"

  defp format_uptime(status) when is_binary(status) do
    # Status is like "Up 2 hours" or "Exited (0) 5 minutes ago"
    cond do
      String.starts_with?(status, "Up ") ->
        String.replace(status, "Up ", "")

      String.contains?(status, "Exited") ->
        "Stopped"

      true ->
        status
    end
  end

  defp format_uptime(_), do: "—"
end
