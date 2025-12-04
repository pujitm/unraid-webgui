defmodule UnraidWeb.VmLive do
  @moduledoc """
  Virtual Machines management page.

  Displays VMs using composable card primitives with:
    * Hierarchical folders containing VMs
    * Expandable details (storage devices, network interfaces)
    * Search filtering
    * Selection and drag/drop support
  """

  use UnraidWeb, :live_view

  alias Unraid.VirtualMachine
  alias Unraid.Tree

  import UnraidWeb.CardComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:vms, [])
      |> assign(:selected_ids, MapSet.new())
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:show_stopped, true)
      |> assign(:dragging?, false)
      |> assign(:search_query, "")

    if connected?(socket) do
      send(self(), :load_vms)
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Header --%>
      <div class="flex items-center justify-between gap-4">
        <div class="flex-1 max-w-md">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="w-5 h-5 absolute left-3 top-1/2 -translate-y-1/2 opacity-50"
            />
            <input
              type="text"
              placeholder="Search virtual machines..."
              class="input input-bordered w-full pl-10"
              value={@search_query}
              phx-keyup="search"
              phx-debounce="200"
            />
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button class="btn btn-ghost gap-2" phx-click="refresh">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            Refresh
          </button>
          <button class="btn btn-primary gap-2" phx-click="add_vm">
            <.icon name="hero-plus" class="w-4 h-4" />
            Add VM
          </button>
          <button class="btn btn-ghost gap-2" phx-click="add_folder">
            <.icon name="hero-folder-plus" class="w-4 h-4" />
            Add Folder
          </button>
        </div>
      </div>

      <%!-- Bulk actions --%>
      <div :if={MapSet.size(@selected_ids) > 0} class="flex items-center gap-4">
        <span class="text-sm text-base-content/60">
          {MapSet.size(@selected_ids)} selected
        </span>
        <button class="btn btn-sm btn-ghost gap-1" phx-click="start_selected">
          <.icon name="hero-play" class="w-4 h-4" /> Start
        </button>
        <button class="btn btn-sm btn-ghost gap-1" phx-click="stop_selected">
          <.icon name="hero-stop" class="w-4 h-4" /> Stop
        </button>
      </div>

      <%!-- Loading skeleton --%>
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

      <%!-- Empty state --%>
      <div
        :if={not @loading and filtered_vms(@vms, @search_query) == []}
        class="text-center py-12"
      >
        <.icon name="hero-computer-desktop" class="w-12 h-12 mx-auto opacity-30 mb-4" />
        <h3 class="text-lg font-medium mb-2">No virtual machines found</h3>
        <p :if={@search_query != ""} class="text-base-content/60">
          No VMs match your search "{@search_query}"
        </p>
        <p :if={@search_query == "" and @vms == []} class="text-base-content/60">
          Create your first VM to get started
        </p>
      </div>

      <%!-- VM Cards using composable primitives --%>
      <.card_list
        :if={not @loading and filtered_vms(@vms, @search_query) != []}
        id="vms-list"
        rows={filtered_vms(@vms, @search_query)}
        row_id={fn row -> row.id end}
        expanded_ids={MapSet.to_list(@expanded_ids)}
        selected_ids={MapSet.to_list(@selected_ids)}
        on_expand="toggle_expand"
        on_select="selection_changed"
        on_drop="row_dropped"
        on_drag="row_drag"
        selectable={true}
        draggable={true}
      >
        <:col_header class="flex-1">Name / Description</:col_header>
        <:col_header class="w-44 text-center">Resources</:col_header>
        <:col_header class="w-36 text-center">Network</:col_header>
        <:col_header class="w-28 text-center">Status</:col_header>
        <:col_header class="w-56 text-right">Actions</:col_header>

        <:row :let={slot}>
          <%= if slot.type == :folder do %>
            <.folder_row
              row={slot.row}
              expanded={slot.expanded}
              has_children={slot.has_children}
            />
          <% else %>
            <.vm_row
              vm={slot.row}
              expanded={slot.expanded}
              selected={slot.selected}
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
  # VM Row Component
  # ---------------------------------------------------------------------------

  attr :vm, :any, required: true
  attr :expanded, :boolean, default: false
  attr :selected, :boolean, default: false

  defp vm_row(assigns) do
    ~H"""
    <.card selected={@selected}>
      <.card_row>
        <.expand_toggle expanded={@expanded} has_content={true} />
        <.select_checkbox selected={@selected} id={@vm.id} />
        <.drag_handle />

        <%!-- Name / Description --%>
        <div class="flex items-center gap-3 flex-1 min-w-0">
          <.card_avatar name={@vm.name} />
          <div class="min-w-0">
            <div class="font-medium truncate">{@vm.name}</div>
            <div class="text-sm opacity-50 truncate">{@vm.description || "Virtual Machine"}</div>
          </div>
        </div>

        <%!-- Resources --%>
        <div class="w-44 flex items-center justify-center gap-3">
          <.card_metric label="CPU" value={@vm.cpu_cores} />
          <.card_metric label="RAM" value={VirtualMachine.format_memory(@vm.memory_mb)} />
          <.card_metric
            label="DISK"
            value={"#{@vm.disk_count} / #{VirtualMachine.format_bytes(@vm.disk_total_bytes)}"}
          />
        </div>

        <%!-- Network / IP Address --%>
        <div class="w-36 text-center">
          <div class="text-xs opacity-50 uppercase">IP Address</div>
          <div class="text-sm">{@vm.ip_address || "Requires guest running"}</div>
        </div>

        <%!-- Status --%>
        <div class="w-28 flex justify-center">
          <.card_status state={@vm.state} />
        </div>

        <%!-- Actions --%>
        <div class="w-56 flex items-center justify-end gap-2">
          <label class="flex items-center gap-2 cursor-pointer">
            <span class="text-xs opacity-60 uppercase">Autostart</span>
            <input
              type="checkbox"
              class="toggle toggle-sm"
              checked={@vm.autostart}
              phx-click="toggle_autostart"
              phx-value-id={@vm.id}
            />
          </label>

          <button
            :if={@vm.state == :stopped}
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="start"
            phx-value-id={@vm.id}
            title="Start"
          >
            <.icon name="hero-play" class="w-5 h-5" />
          </button>
          <button
            :if={@vm.state == :running}
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="stop"
            phx-value-id={@vm.id}
            title="Stop"
          >
            <.icon name="hero-stop" class="w-5 h-5 fill-current" />
          </button>
          <button
            :if={@vm.state == :paused}
            class="btn btn-ghost btn-sm btn-circle"
            phx-click="resume"
            phx-value-id={@vm.id}
            title="Resume"
          >
            <.icon name="hero-play" class="w-5 h-5" />
          </button>

          <.vm_dropdown vm={@vm} />
        </div>
      </.card_row>

      <%!-- Expanded Details --%>
      <.card_expanded :if={@expanded}>
        <.vm_details vm={@vm} />
      </.card_expanded>
    </.card>
    """
  end

  # ---------------------------------------------------------------------------
  # VM Dropdown Menu
  # ---------------------------------------------------------------------------

  attr :vm, :any, required: true

  defp vm_dropdown(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <label tabindex="0" class="btn btn-ghost btn-sm btn-circle">
        <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
      </label>
      <ul
        tabindex="0"
        class="dropdown-content menu p-2 shadow-lg bg-base-100 border border-base-300 rounded-box w-52 z-50"
      >
        <li :if={@vm.state == :stopped}>
          <a phx-click="start" phx-value-id={@vm.id}>
            <.icon name="hero-play" class="w-4 h-4" /> Start
          </a>
        </li>
        <li :if={@vm.state == :running}>
          <a phx-click="stop" phx-value-id={@vm.id}>
            <.icon name="hero-stop" class="w-4 h-4" /> Stop
          </a>
        </li>
        <li :if={@vm.state == :running}>
          <a phx-click="pause" phx-value-id={@vm.id}>
            <.icon name="hero-pause" class="w-4 h-4" /> Pause
          </a>
        </li>
        <li :if={@vm.state == :paused}>
          <a phx-click="resume" phx-value-id={@vm.id}>
            <.icon name="hero-play" class="w-4 h-4" /> Resume
          </a>
        </li>
        <li :if={@vm.state == :running}>
          <a phx-click="restart" phx-value-id={@vm.id}>
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Restart
          </a>
        </li>
        <li :if={@vm.state == :running}>
          <a phx-click="force_stop" phx-value-id={@vm.id}>
            <.icon name="hero-bolt" class="w-4 h-4" /> Force Stop
          </a>
        </li>
        <.menu_separator />
        <li>
          <a phx-click="edit" phx-value-id={@vm.id}>
            <.icon name="hero-pencil" class="w-4 h-4" /> Edit
          </a>
        </li>
        <li>
          <a phx-click="clone" phx-value-id={@vm.id}>
            <.icon name="hero-document-duplicate" class="w-4 h-4" /> Clone
          </a>
        </li>
        <.menu_separator />
        <li>
          <a
            phx-click="remove"
            phx-value-id={@vm.id}
            data-confirm={"Are you sure you want to remove #{@vm.name}?"}
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
  # VM Expanded Details
  # ---------------------------------------------------------------------------

  attr :vm, :any, required: true

  defp vm_details(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Graphics Driver --%>
      <div :if={@vm.graphics_driver} class="flex items-center gap-2">
        <.icon name="hero-tv" class="w-5 h-5 opacity-60" />
        <span class="text-sm opacity-60">Graphics Driver:</span>
        <span class="badge badge-outline">{@vm.graphics_driver}</span>
      </div>

      <%!-- Storage Devices --%>
      <div :if={@vm.storage_devices != []}>
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-circle-stack" class="w-5 h-5 opacity-60" />
            <span class="font-medium uppercase text-sm">Storage Devices</span>
          </div>
          <span class="badge badge-outline">
            {length(@vm.storage_devices)} Devices / {VirtualMachine.format_bytes(@vm.disk_total_bytes)} Total
          </span>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs opacity-60 uppercase">
                <th>Path / Source</th>
                <th>Serial</th>
                <th>Bus</th>
                <th>Capacity</th>
                <th>Allocated</th>
                <th>Boot Order</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{device, idx} <- Enum.with_index(@vm.storage_devices)}>
                <td class="font-mono text-sm">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-circle-stack" class="w-4 h-4 opacity-50" />
                    <span class="truncate max-w-xs" title={device.path}>{device.path}</span>
                  </div>
                </td>
                <td class="text-sm">{device.serial || "—"}</td>
                <td class="text-sm">{device.bus}</td>
                <td class="text-sm">{VirtualMachine.format_bytes(device.capacity_bytes)}</td>
                <td class="text-sm">{VirtualMachine.format_bytes(device.allocated_bytes)}</td>
                <td class="text-sm">{device.boot_order || if(idx == 0, do: "1", else: "Not set")}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Network Interfaces --%>
      <div :if={@vm.network_interfaces != []}>
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-signal" class="w-5 h-5 opacity-60" />
          <span class="font-medium uppercase text-sm">Network Interfaces</span>
        </div>

        <div class="flex flex-wrap gap-3">
          <div
            :for={iface <- @vm.network_interfaces}
            class="card bg-base-200 px-4 py-3 min-w-[200px]"
          >
            <div class="flex items-center gap-2 mb-1">
              <span class={[
                "w-2 h-2 rounded-full",
                if(@vm.state == :running, do: "bg-success", else: "bg-base-content/30")
              ]}></span>
              <span class="font-mono text-sm">{iface.mac}</span>
              <span :if={@vm.ip_address} class="text-sm opacity-60">{@vm.ip_address}</span>
            </div>
            <div class="text-xs opacity-60">
              {iface.bridge || "default"} &bull; {iface.type}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - Data Loading
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_vms, socket) do
    pid = self()

    Task.start(fn ->
      vms = VirtualMachine.list_all()
      send(pid, {:vms_loaded, vms})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:vms_loaded, vms}, socket) do
    {:noreply, assign(socket, loading: false, vms: vms)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Event Handlers - User Actions
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    send(self(), :load_vms)
    {:noreply, assign(socket, loading: true)}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id, "expanded" => expanded}, socket) do
    expanded_ids =
      if expanded do
        MapSet.put(socket.assigns.expanded_ids, id)
      else
        MapSet.delete(socket.assigns.expanded_ids, id)
      end

    {:noreply, assign(socket, expanded_ids: expanded_ids)}
  end

  @impl true
  def handle_event("selection_changed", %{"selected_ids" => ids}, socket) do
    selected = ids |> List.wrap() |> MapSet.new()
    {:noreply, assign(socket, selected_ids: selected)}
  end

  # VM Actions (placeholders - UI only)
  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    IO.puts("Starting VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop", %{"id" => id}, socket) do
    IO.puts("Stopping VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("force_stop", %{"id" => id}, socket) do
    IO.puts("Force stopping VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("restart", %{"id" => id}, socket) do
    IO.puts("Restarting VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    IO.puts("Pausing VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("resume", %{"id" => id}, socket) do
    IO.puts("Resuming VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_autostart", %{"id" => id}, socket) do
    IO.puts("Toggling autostart for VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    IO.puts("Edit VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("clone", %{"id" => id}, socket) do
    IO.puts("Clone VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove", %{"id" => id}, socket) do
    IO.puts("Remove VM: #{id}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_vm", _params, socket) do
    IO.puts("Add VM clicked")
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_folder", _params, socket) do
    IO.puts("Add Folder clicked")
    {:noreply, socket}
  end

  # Bulk actions
  @impl true
  def handle_event("start_selected", _params, socket) do
    Enum.each(socket.assigns.selected_ids, fn id ->
      IO.puts("Starting VM: #{id}")
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_selected", _params, socket) do
    Enum.each(socket.assigns.selected_ids, fn id ->
      IO.puts("Stopping VM: #{id}")
    end)

    {:noreply, socket}
  end

  # Drag & drop
  @impl true
  def handle_event("row_drag", %{"state" => "start"}, socket) do
    {:noreply, assign(socket, :dragging?, true)}
  end

  def handle_event("row_drag", %{"state" => "end"}, socket) do
    {:noreply, assign(socket, :dragging?, false)}
  end

  @impl true
  def handle_event("row_dropped", params, socket) do
    case Tree.apply_drop(socket.assigns.vms, params) do
      {:ok, updated_vms} ->
        valid_ids = Tree.collect_ids(updated_vms)

        selected =
          socket.assigns.selected_ids
          |> MapSet.intersection(MapSet.new(valid_ids))

        {:noreply,
         socket
         |> assign(:vms, updated_vms)
         |> assign(:selected_ids, selected)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp filtered_vms(vms, ""), do: vms
  defp filtered_vms(vms, nil), do: vms

  defp filtered_vms(vms, query) do
    query = String.downcase(query)

    Enum.filter(vms, fn vm ->
      name = Map.get(vm, :name) || ""
      desc = Map.get(vm, :description) || ""
      String.contains?(String.downcase(name), query) or String.contains?(String.downcase(desc), query)
    end)
  end

  defp count_running(children) do
    Enum.count(children, fn child ->
      Map.get(child, :state) == :running
    end)
  end
end
