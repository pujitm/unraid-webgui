defmodule UnraidViewWeb.DockerCardDemoLive do
  @moduledoc """
  Docker container card demo page.

  Displays Docker containers using the rich_card component as an alternative
  to the table-based view. Demonstrates card-based layout with:

    * Expandable cards with nested children
    * Drag & drop reordering
    * Selection support
    * Real-time stats via standard LiveView updates

  Visit `/docker/card` to see this demo.
  """

  use UnraidViewWeb, :live_view

  alias UnraidView.Docker
  alias UnraidView.Docker.StatsStreamer
  alias UnraidView.Tree

  import UnraidViewWeb.RichCardComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:containers, [])
      |> assign(:selected_ids, MapSet.new())
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:stats_cache, %{})
      |> assign(:pending_actions, %{})
      |> assign(:show_stopped, true)
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
          <h1 class="text-2xl font-bold">Docker Containers (Card View)</h1>
          <p class="text-sm text-base-content/60">
            Card-based container management with drag & drop reordering.
          </p>
        </div>
        <div class="flex gap-2">
          <a href="/docker" class="btn btn-sm btn-ghost">
            <.icon name="hero-table-cells" class="w-4 h-4" /> Table View
          </a>
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
        </div>
      </div>

      <div class="flex items-center gap-4 mb-4">
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
          {container_count_label(@containers, @show_stopped)}
        </span>
      </div>

      <div :if={@loading} class="space-y-3">
        <div :for={_ <- 1..4} class="card border border-base-300 bg-base-100 animate-pulse">
          <div class="card-body p-4 flex flex-row items-center gap-4">
            <div class="w-10 h-10 bg-base-300 rounded-lg"></div>
            <div class="flex-1 space-y-2">
              <div class="h-4 bg-base-300 rounded w-48"></div>
              <div class="h-3 bg-base-300 rounded w-32"></div>
            </div>
            <div class="h-6 bg-base-300 rounded w-16"></div>
          </div>
        </div>
      </div>

      <.rich_card
        :if={not @loading}
        id="docker-cards"
        rows={visible_containers(@containers, @show_stopped)}
        row_id={fn c -> c.id end}
        row_drop_event="docker:row_dropped"
        row_drag_event="docker:row_drag"
        selectable={true}
        selected_row_ids={MapSet.to_list(@selected_ids)}
        selection_event="selection_changed"
        expanded_ids={MapSet.to_list(@expanded_ids)}
      >
        <:col_header class="flex-1">Name / Description</:col_header>
        <:col_header class="w-32 text-center">Resources</:col_header>
        <:col_header class="w-24 text-center">Network</:col_header>
        <:col_header class="w-24 text-center">Status</:col_header>
        <:col_header class="w-32 text-right">Actions</:col_header>

        <:header :let={slot}>
          <div class="flex items-center gap-3">
            <.card_avatar icon={slot.row.icon} name={slot.row.name} />
            <div class="min-w-0">
              <div class="font-medium truncate">{slot.row.name}</div>
              <div class="text-sm opacity-50 truncate">{slot.row.image}</div>
            </div>
          </div>
        </:header>

        <:metrics :let={slot}>
          <.card_metric label="CPU" value={format_cpu(slot.row.cpu_percent)} />
          <.card_metric label="MEM" value={slot.row.memory_usage || "—"} />
        </:metrics>

        <:status :let={slot}>
          <.card_status state={slot.row.state} />
        </:status>

        <:action :let={slot}>
          <div class="flex items-center gap-2">
            <button
              :if={slot.row.state == :stopped}
              class="btn btn-ghost btn-sm btn-circle"
              phx-click="start"
              phx-value-id={slot.row.id}
              title="Start"
            >
              <.icon name="hero-play" class="w-4 h-4" />
            </button>
            <button
              :if={slot.row.state == :running}
              class="btn btn-ghost btn-sm btn-circle"
              phx-click="stop"
              phx-value-id={slot.row.id}
              title="Stop"
            >
              <.icon name="hero-stop" class="w-4 h-4" />
            </button>
            <div class="dropdown dropdown-end">
              <label tabindex="0" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
              </label>
              <ul
                tabindex="0"
                class="dropdown-content menu p-2 shadow-lg bg-base-100 border border-base-300 rounded-box w-44"
              >
                <li>
                  <a phx-click="restart" phx-value-id={slot.row.id}>
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> Restart
                  </a>
                </li>
                <li :if={slot.row.state == :running}>
                  <a phx-click="pause" phx-value-id={slot.row.id}>
                    <.icon name="hero-pause" class="w-4 h-4" /> Pause
                  </a>
                </li>
                <li :if={slot.row.state == :paused}>
                  <a phx-click="resume" phx-value-id={slot.row.id}>
                    <.icon name="hero-play" class="w-4 h-4" /> Resume
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
                    phx-click="remove"
                    phx-value-id={slot.row.id}
                    data-confirm={"Are you sure you want to remove #{slot.row.name}?"}
                    class="text-error"
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> Remove
                  </a>
                </li>
              </ul>
            </div>
          </div>
        </:action>
      </.rich_card>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - Data Loading
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_containers, socket) do
    pid = self()

    Task.start(fn ->
      containers = Docker.list_containers()
      send(pid, {:containers_loaded, containers})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:containers_loaded, containers}, socket) do
    containers =
      Enum.map(containers, fn container ->
        case Map.get(socket.assigns.stats_cache, container.id) do
          nil -> container
          stats -> Docker.Container.with_stats(container, stats)
        end
      end)

    {:noreply, assign(socket, loading: false, containers: containers)}
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - PubSub
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:stats_updated, stats}, socket) do
    if socket.assigns.dragging? do
      {:noreply, socket}
    else
      stats_map = Map.new(stats, &{&1.id, &1})
      new_cache = Map.merge(socket.assigns.stats_cache, stats_map)

      containers =
        Enum.map(socket.assigns.containers, fn c ->
          case Map.get(stats_map, c.id) do
            nil -> c
            stat -> Docker.Container.with_stats(c, stat)
          end
        end)

      {:noreply, assign(socket, stats_cache: new_cache, containers: containers)}
    end
  end

  @impl true
  def handle_info({:docker_event, %{action: action, container_id: container_id}}, socket)
      when action in ["start", "stop", "die", "pause", "unpause", "destroy", "create"] do
    pending = Map.delete(socket.assigns.pending_actions, container_id)
    new_state = action_to_state(action)

    containers =
      Enum.map(socket.assigns.containers, fn c ->
        if c.id == container_id, do: %{c | state: new_state}, else: c
      end)

    socket =
      socket
      |> assign(:pending_actions, pending)
      |> assign(:containers, containers)

    send(self(), :load_containers)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - User Actions
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_show_stopped", _params, socket) do
    {:noreply, assign(socket, show_stopped: !socket.assigns.show_stopped)}
  end

  @impl true
  def handle_event("selection_changed", %{"selected_ids" => ids}, socket) do
    selected = ids |> List.wrap() |> MapSet.new()
    {:noreply, assign(socket, selected_ids: selected)}
  end

  @impl true
  def handle_event("rich_card:toggle_expand", %{"card_id" => card_id, "expanded" => expanded}, socket) do
    expanded_ids =
      if expanded do
        MapSet.put(socket.assigns.expanded_ids, card_id)
      else
        MapSet.delete(socket.assigns.expanded_ids, card_id)
      end

    {:noreply, assign(socket, expanded_ids: expanded_ids)}
  end

  # Container actions
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

  # Drag & drop
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

  defp start_container_action(socket, id, action_type, action_fn) do
    pending = Map.put(socket.assigns.pending_actions, id, action_type)
    socket = assign(socket, :pending_actions, pending)
    Task.start(fn -> action_fn.(id) end)
    socket
  end

  defp visible_containers(containers, show_stopped) do
    if show_stopped do
      containers
    else
      Enum.filter(containers, &(&1.state != :stopped))
    end
  end

  defp container_count_label(containers, show_stopped) do
    visible = visible_containers(containers, show_stopped)
    total = length(containers)
    shown = length(visible)

    if shown == total do
      "#{total} containers"
    else
      "#{shown} of #{total} containers"
    end
  end

  defp format_cpu(nil), do: "—"
  defp format_cpu(cpu) when is_number(cpu), do: "#{Float.round(cpu * 1.0, 1)}%"
  defp format_cpu(cpu) when is_binary(cpu), do: cpu
  defp format_cpu(_), do: "—"

  defp action_to_state("start"), do: :running
  defp action_to_state("stop"), do: :stopped
  defp action_to_state("die"), do: :stopped
  defp action_to_state("pause"), do: :paused
  defp action_to_state("unpause"), do: :running
  defp action_to_state("create"), do: :created
  defp action_to_state("destroy"), do: :stopped
  defp action_to_state(_), do: :stopped
end
