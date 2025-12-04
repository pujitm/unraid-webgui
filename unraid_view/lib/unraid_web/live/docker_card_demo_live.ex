defmodule UnraidWeb.DockerCardDemoLive do
  @moduledoc """
  Docker container card demo page.

  Displays Docker containers using composable card primitives with:

    * Expandable cards with nested children (folders)
    * Drag & drop reordering
    * Selection support
    * Real-time stats via standard LiveView updates

  Visit `/docker/card` to see this demo.
  """

  use UnraidWeb, :live_view

  alias Unraid.Docker
  alias Unraid.Docker.StatsServer
  alias Unraid.Docker.TailscaleService
  alias Unraid.Tree

  import UnraidWeb.CardComponents

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
      |> assign(:tailscale_cache, %{})
      |> assign(:tailscale_loading, MapSet.new())

    if connected?(socket) do
      Docker.subscribe()
      StatsServer.request_stats()
      send(self(), :load_containers)
    end

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    StatsServer.release_stats()
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

      <.card_list
        :if={not @loading}
        id="docker-cards"
        rows={visible_containers(@containers, @show_stopped)}
        row_id={fn c -> c.id end}
        expanded_ids={MapSet.to_list(@expanded_ids)}
        selected_ids={MapSet.to_list(@selected_ids)}
        on_expand="toggle_expand"
        on_select="selection_changed"
        on_drop="docker:row_dropped"
        on_drag="docker:row_drag"
        selectable={true}
        draggable={true}
      >
        <:col_header class="flex-1">Name / Description</:col_header>
        <:col_header class="w-32 text-center">Resources</:col_header>
        <:col_header class="w-24 text-center">Network</:col_header>
        <:col_header class="w-24 text-center">Status</:col_header>
        <:col_header class="w-32 text-right">Actions</:col_header>

        <:row :let={slot}>
          <%= if slot.type == :folder do %>
            <.folder_row
              row={slot.row}
              expanded={slot.expanded}
              has_children={slot.has_children}
            />
          <% else %>
            <.container_row
              container={slot.row}
              selected={slot.selected}
              expanded={slot.expanded}
              tailscale_status={Map.get(@tailscale_cache, slot.row.id)}
              tailscale_loading={MapSet.member?(@tailscale_loading, slot.row.id)}
            />
          <% end %>
        </:row>
      </.card_list>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Folder Row Component
  # ---------------------------------------------------------------------------

  attr :row, :map, required: true
  attr :expanded, :boolean, default: false
  attr :has_children, :boolean, default: false

  defp folder_row(assigns) do
    running_count = count_running(assigns.row.children || [])
    total_count = length(assigns.row.children || [])
    assigns = assign(assigns, running_count: running_count, total_count: total_count)

    ~H"""
    <.card variant={:folder}>
      <.card_row>
        <.expand_toggle expanded={@expanded} has_content={@has_children} />
        <.drag_handle />

        <div class="flex items-center gap-3 flex-1">
          <.icon name="hero-folder" class="w-6 h-6 text-primary" />
          <span class="font-medium">{@row.name}</span>
          <span class="badge badge-outline text-xs">
            {@running_count} / {@total_count} Running
          </span>
        </div>
      </.card_row>
    </.card>
    """
  end

  # ---------------------------------------------------------------------------
  # Container Row Component
  # ---------------------------------------------------------------------------

  attr :container, :map, required: true
  attr :selected, :boolean, default: false
  attr :expanded, :boolean, default: false
  attr :tailscale_status, :any, default: nil
  attr :tailscale_loading, :boolean, default: false

  defp container_row(assigns) do
    ~H"""
    <.card selected={@selected}>
      <.card_row>
        <.expand_toggle expanded={@expanded} has_content={true} />
        <.select_checkbox selected={@selected} id={@container.id} />
        <.drag_handle />

        <%!-- Name / Description --%>
        <div class="flex items-center gap-3 flex-1 min-w-0">
          <.card_avatar icon={@container.icon} name={@container.name} />
          <div class="min-w-0">
            <div class="font-medium truncate flex items-center gap-2">
              {@container.name}
              <span
                :if={@container.tailscale_enabled}
                class="badge badge-sm badge-outline gap-1"
                title="Tailscale enabled"
              >
                <.tailscale_icon class="w-3 h-3" /> TS
              </span>
            </div>
            <div class="text-sm opacity-50 truncate">{@container.image}</div>
          </div>
        </div>

        <%!-- Resources --%>
        <div class="w-32 flex items-center justify-center gap-3">
          <.card_metric label="CPU" value={format_cpu(@container.cpu_percent)} />
          <.card_metric label="MEM" value={@container.memory_usage || "—"} />
        </div>

        <%!-- Network --%>
        <div class="w-24 text-center text-sm">
          {format_ports(@container.ports)}
        </div>

        <%!-- Status --%>
        <div class="w-24 flex justify-center">
          <.card_status state={@container.state} />
        </div>

        <%!-- Actions --%>
        <div class="w-32 flex items-center justify-end gap-1">
          <button
            :if={@container.state == :stopped}
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="start"
            phx-value-id={@container.id}
            title="Start"
          >
            <.icon name="hero-play" class="w-4 h-4" />
          </button>
          <button
            :if={@container.state == :running}
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="stop"
            phx-value-id={@container.id}
            title="Stop"
          >
            <.icon name="hero-stop" class="w-4 h-4" />
          </button>

          <.container_dropdown container={@container} tailscale_status={@tailscale_status} />
        </div>
      </.card_row>

      <%!-- Expanded Details --%>
      <.card_expanded :if={@expanded}>
        <.container_details
          container={@container}
          tailscale_status={@tailscale_status}
          tailscale_loading={@tailscale_loading}
        />
      </.card_expanded>
    </.card>
    """
  end

  # ---------------------------------------------------------------------------
  # Container Dropdown Menu
  # ---------------------------------------------------------------------------

  attr :container, :map, required: true
  attr :tailscale_status, :any, default: nil

  defp container_dropdown(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <label tabindex="0" class="btn btn-ghost btn-sm btn-circle">
        <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
      </label>
      <ul
        tabindex="0"
        class="dropdown-content menu p-2 shadow-lg bg-base-100 border border-base-300 rounded-box w-48 z-50"
      >
        <li>
          <a phx-click="restart" phx-value-id={@container.id}>
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Restart
          </a>
        </li>
        <li :if={@container.state == :running}>
          <a phx-click="pause" phx-value-id={@container.id}>
            <.icon name="hero-pause" class="w-4 h-4" /> Pause
          </a>
        </li>
        <li :if={@container.state == :paused}>
          <a phx-click="resume" phx-value-id={@container.id}>
            <.icon name="hero-play" class="w-4 h-4" /> Resume
          </a>
        </li>
        <li :if={@container.web_ui}>
          <a href={@container.web_ui} target="_blank" rel="noopener">
            <.icon name="hero-globe-alt" class="w-4 h-4" /> WebUI
          </a>
        </li>
        <li :if={@tailscale_status && @tailscale_status.web_ui_url}>
          <a href={@tailscale_status.web_ui_url} target="_blank" rel="noopener">
            <.tailscale_icon class="w-4 h-4" /> Tailscale WebUI
          </a>
        </li>
        <.menu_separator />
        <li>
          <a
            phx-click="remove"
            phx-value-id={@container.id}
            data-confirm={"Are you sure you want to remove #{@container.name}?"}
            class="text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Remove
          </a>
        </li>
      </ul>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Container Details (Expanded View)
  # ---------------------------------------------------------------------------

  attr :container, :map, required: true
  attr :tailscale_status, :any, default: nil
  attr :tailscale_loading, :boolean, default: false

  defp container_details(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Ports Section --%>
      <div :if={@container.ports != []}>
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-server-stack" class="w-5 h-5 opacity-60" />
          <span class="font-medium uppercase text-sm">Ports</span>
          <span class="badge badge-outline text-xs">{length(@container.ports)} mapped</span>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs opacity-60 uppercase">
                <th>Host Port</th>
                <th>Container Port</th>
                <th>Protocol</th>
                <th>Bind IP</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={port <- @container.ports}>
                <td class="font-mono">{port.public || "—"}</td>
                <td class="font-mono">{port.private}</td>
                <td class="uppercase">{port.type}</td>
                <td class="font-mono text-xs">{port.ip || "0.0.0.0"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Volumes Section --%>
      <div :if={@container.volumes != []}>
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-circle-stack" class="w-5 h-5 opacity-60" />
          <span class="font-medium uppercase text-sm">Volumes</span>
          <span class="badge badge-outline text-xs">{length(@container.volumes)} mounts</span>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs opacity-60 uppercase">
                <th>Host Path</th>
                <th>Container Path</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={volume <- @container.volumes}>
                <% [source, dest] = parse_volume(volume) %>
                <td class="font-mono text-xs max-w-xs truncate" title={source}>{source}</td>
                <td class="font-mono text-xs max-w-xs truncate" title={dest}>{dest}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Networks Section --%>
      <div :if={map_size(@container.networks) > 0}>
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-signal" class="w-5 h-5 opacity-60" />
          <span class="font-medium uppercase text-sm">Networks</span>
        </div>

        <div class="flex flex-wrap gap-3">
          <div
            :for={{name, config} <- @container.networks}
            class="card bg-base-200 px-4 py-3 min-w-[200px]"
          >
            <div class="flex items-center gap-2 mb-1">
              <span class={[
                "w-2 h-2 rounded-full",
                if(@container.state == :running, do: "bg-success", else: "bg-base-content/30")
              ]}></span>
              <span class="font-medium">{name}</span>
            </div>
            <div class="font-mono text-sm">{config.ip || "No IP assigned"}</div>
          </div>
        </div>
      </div>

      <%!-- Tailscale Section --%>
      <.tailscale_section
        :if={@container.tailscale_enabled}
        container={@container}
        status={@tailscale_status}
        loading={@tailscale_loading}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tailscale Section Component
  # ---------------------------------------------------------------------------

  attr :container, :map, required: true
  attr :status, :any, default: nil
  attr :loading, :boolean, default: false

  defp tailscale_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <.tailscale_icon class="w-5 h-5 opacity-60" />
          <span class="font-medium uppercase text-sm">Tailscale</span>
        </div>
        <button
          :if={@status}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="tailscale_refresh"
          phx-value-id={@container.id}
          disabled={@loading}
        >
          <.icon name="hero-arrow-path" class={if @loading, do: "w-4 h-4 animate-spin", else: "w-4 h-4"} />
        </button>
      </div>

      <%!-- Loading State --%>
      <div :if={@loading && !@status} class="flex gap-4">
        <div class="skeleton h-20 w-1/4"></div>
        <div class="skeleton h-20 w-1/4"></div>
        <div class="skeleton h-20 w-1/4"></div>
        <div class="skeleton h-20 w-1/4"></div>
      </div>

      <%!-- Container not running --%>
      <div :if={!@loading && !@status && @container.state != :running} class="text-sm opacity-60">
        Start the container to view Tailscale status
      </div>

      <%!-- Waiting for status --%>
      <div :if={!@loading && !@status && @container.state == :running} class="text-sm opacity-60">
        Loading Tailscale status...
      </div>

      <%!-- Status Display --%>
      <div :if={@status} class="space-y-4">
        <%!-- NeedsLogin Warning --%>
        <div :if={@status.backend_state == "NeedsLogin"} class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <div>
            <div class="font-medium">Authentication Required</div>
            <p class="text-sm opacity-80">Tailscale needs to be authenticated in this container.</p>
            <a
              :if={@status.auth_url}
              href={@status.auth_url}
              target="_blank"
              rel="noopener"
              class="link text-sm mt-1 inline-flex items-center gap-1"
            >
              Click here to authenticate
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
            </a>
          </div>
        </div>

        <%!-- Status Cards Grid --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <%!-- Online Status --%>
          <div class="card bg-base-200 p-3">
            <div class="text-xs opacity-60 uppercase">Status</div>
            <div class="flex items-center gap-1.5 mt-1">
              <span class={[
                "w-2 h-2 rounded-full",
                if(@status.online, do: "bg-success", else: "bg-error")
              ]}></span>
              <span>{if @status.online, do: "Online", else: "Offline"}</span>
            </div>
          </div>

          <%!-- Version --%>
          <div class="card bg-base-200 p-3">
            <div class="text-xs opacity-60 uppercase">Version</div>
            <div class="mt-1 flex items-center gap-1.5">
              <span>v{@status.version || "—"}</span>
              <span :if={@status.update_available} class="badge badge-warning badge-xs">
                Update
              </span>
            </div>
          </div>

          <%!-- Hostname --%>
          <div class="card bg-base-200 p-3">
            <div class="text-xs opacity-60 uppercase">Hostname</div>
            <div class="mt-1 truncate" title={@status.hostname || @status.dns_name}>
              {@status.hostname || @status.dns_name || "—"}
            </div>
          </div>

          <%!-- Tailscale IP --%>
          <div class="card bg-base-200 p-3">
            <div class="text-xs opacity-60 uppercase">Tailscale IP</div>
            <div class="mt-1 font-mono text-xs">
              {List.first(@status.tailscale_ips) || "—"}
            </div>
          </div>
        </div>

        <%!-- Additional Details --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-x-8 gap-y-2 text-sm">
          <%!-- DERP Relay --%>
          <div :if={@status.relay_name || @status.relay} class="flex justify-between py-1">
            <span class="opacity-60">DERP Relay</span>
            <span>{@status.relay_name || @status.relay}</span>
          </div>

          <%!-- Exit Node --%>
          <div class="flex justify-between py-1">
            <span class="opacity-60">Exit Node</span>
            <span :if={@status.is_exit_node} class="text-success">This is an exit node</span>
            <span :if={@status.exit_node_status} class="flex items-center gap-1">
              <span class={[
                "w-2 h-2 rounded-full",
                if(@status.exit_node_status.online, do: "bg-success", else: "bg-error")
              ]}></span>
              {List.first(@status.exit_node_status.tailscale_ips) || "Connected"}
            </span>
            <span :if={!@status.is_exit_node && !@status.exit_node_status} class="opacity-50">
              Not configured
            </span>
          </div>

          <%!-- Routes --%>
          <div :if={@status.primary_routes != []} class="flex justify-between py-1">
            <span class="opacity-60">Routes</span>
            <span class="font-mono text-xs">{Enum.join(@status.primary_routes, ", ")}</span>
          </div>

          <%!-- WebUI --%>
          <div :if={@status.web_ui_url} class="flex justify-between py-1">
            <span class="opacity-60">WebUI</span>
            <a
              href={@status.web_ui_url}
              target="_blank"
              rel="noopener"
              class="link link-primary flex items-center gap-1"
            >
              Open <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
            </a>
          </div>

          <%!-- Key Expiry --%>
          <div :if={@status.key_expiry} class="flex justify-between py-1">
            <span class="opacity-60">Key Expiry</span>
            <span class={@status.key_expired && "text-error"}>
              {format_date(@status.key_expiry)}
              <span :if={@status.key_expired} class="ml-1">(Expired!)</span>
              <span :if={!@status.key_expired && @status.key_expiry_days} class="opacity-50 ml-1">
                ({@status.key_expiry_days} days)
              </span>
            </span>
          </div>

          <%!-- All IPs --%>
          <div :if={length(@status.tailscale_ips) > 1} class="flex justify-between py-1">
            <span class="opacity-60">All Addresses</span>
            <span class="font-mono text-xs text-right">
              {Enum.join(@status.tailscale_ips, ", ")}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tailscale Icon Component
  # ---------------------------------------------------------------------------

  attr :class, :string, default: nil

  defp tailscale_icon(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <circle cx="12" cy="6" r="3" />
      <circle cx="6" cy="12" r="3" />
      <circle cx="18" cy="12" r="3" />
      <circle cx="12" cy="18" r="3" />
      <circle cx="6" cy="6" r="1.5" opacity="0.5" />
      <circle cx="18" cy="6" r="1.5" opacity="0.5" />
      <circle cx="6" cy="18" r="1.5" opacity="0.5" />
      <circle cx="18" cy="18" r="1.5" opacity="0.5" />
    </svg>
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
  def handle_info({:tailscale_status_result, container_id, result}, socket) do
    status =
      case result do
        {:ok, status} -> status
        {:error, _} -> nil
      end

    socket =
      socket
      |> update(:tailscale_cache, &Map.put(&1, container_id, status))
      |> update(:tailscale_loading, &MapSet.delete(&1, container_id))

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
  def handle_event("toggle_expand", %{"id" => id, "expanded" => expanded}, socket) do
    expanded_ids =
      if expanded do
        MapSet.put(socket.assigns.expanded_ids, id)
      else
        MapSet.delete(socket.assigns.expanded_ids, id)
      end

    socket = assign(socket, expanded_ids: expanded_ids)

    # Trigger Tailscale status loading when expanding a container with Tailscale enabled
    socket =
      if expanded do
        container = Enum.find(socket.assigns.containers, &(&1.id == id))

        if container && container.tailscale_enabled && container.state == :running &&
             !Map.has_key?(socket.assigns.tailscale_cache, id) do
          load_tailscale_status(socket, container)
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
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

  # Tailscale refresh
  @impl true
  def handle_event("tailscale_refresh", %{"id" => id}, socket) do
    container = Enum.find(socket.assigns.containers, &(&1.id == id))

    if container && container.tailscale_enabled && container.state == :running do
      {:noreply, load_tailscale_status(socket, container, force_refresh: true)}
    else
      {:noreply, socket}
    end
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

  defp format_ports(nil), do: "—"
  defp format_ports([]), do: "—"
  defp format_ports(ports) when is_list(ports), do: "#{length(ports)} ports"
  defp format_ports(_), do: "—"

  defp count_running(children) do
    Enum.count(children, fn child ->
      Map.get(child, :state) == :running
    end)
  end

  defp action_to_state("start"), do: :running
  defp action_to_state("stop"), do: :stopped
  defp action_to_state("die"), do: :stopped
  defp action_to_state("pause"), do: :paused
  defp action_to_state("unpause"), do: :running
  defp action_to_state("create"), do: :created
  defp action_to_state("destroy"), do: :stopped
  defp action_to_state(_), do: :stopped

  defp load_tailscale_status(socket, container, opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)
    container_id = container.id

    # Mark as loading
    socket = update(socket, :tailscale_loading, &MapSet.put(&1, container_id))

    # Fetch status async
    pid = self()

    Task.start(fn ->
      labels = %{
        "net.unraid.docker.tailscale.hostname" => container.tailscale_hostname,
        "net.unraid.docker.tailscale.webui" => container.tailscale_webui_template
      }

      result = TailscaleService.get_status(container.name, labels, force_refresh: force_refresh)
      send(pid, {:tailscale_status_result, container_id, result})
    end)

    socket
  end

  defp parse_volume(volume) when is_binary(volume) do
    case String.split(volume, ":", parts: 2) do
      [source, dest] -> [source, dest]
      [source] -> [source, source]
    end
  end

  defp parse_volume(_), do: ["", ""]

  defp format_date(nil), do: "—"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end

  defp format_date(_), do: "—"
end
