defmodule UnraidWeb.RichTableDemoLive do
  @moduledoc """
  Self-contained demo showcasing the `rich_table/1` component in both
  traditional LiveView mode (assigns/patches) and a streaming mode optimized
  for high-frequency updates.

  ### Key ideas for newcomers

  * **LiveView assigns** – The `@demo_rows` assign feeds the initial render,
    while `@demo_state` holds the authoritative copy that we mutate over time.

  * **Chunked updates** – Instead of rewriting all 500 rows every tick we
    only touch `@pulse_chunk_size` rows at a time. This keeps diffs cheap and
    avoids large DOM/style recomputations in the browser.

  * **Push events + JS hook** – The built-in `RichTable` hook listens for a
    `"rich-table:pulse"` event. We push tiny payloads describing the row ids
    that changed and the hook patches those cells in place.

  * **Drag lifecycle** – The hook emits `"demo:row_drag"` events so the server
    can pause the update loop while someone is moving a row. This prevents the
    DOM from shifting underneath the pointer.

  ## Streaming vs. full re-rendering

  The module intentionally combines two strategies so developers unfamiliar
  with Phoenix/Elixir can see the trade-offs:

    * The initial render uses normal LiveView assigns and HEEx templates. This
      keeps the code approachable; you can drop the component into any view and
      get a fully interactive table with sorting, dragging, etc.

    * After mount we switch to small, periodic push events (`rich-table:pulse`)
      that mutate only the cells that changed. This mirrors workloads like
      `docker stats` or stock tickers where hundreds of rows change every few
      hundred milliseconds. Keeping the DOM stable (via `phx-update="ignore"`)
      and sending tiny diffs avoids expensive `performPatch` and style
      recomputation costs on both the server and client.

  Treat this module as a reference implementation you can adapt to your own
  LiveViews when you need high-frequency updates without sacrificing the DX
  benefits of Phoenix LiveView.
  """
  use UnraidWeb, :live_view

  alias Phoenix.LiveView.JS
  alias Unraid.Parse
  alias Unraid.Tree

  @tick_interval 200
  @status_cycle [:healthy, :warning, :offline]
  @pulse_chunk_size 32
  @table_dom_id "rich-table-demo"
  @pulse_chunk_size 50

  # Skip stress rows and timer in test environment for faster tests
  defp test_env?, do: Application.get_env(:unraid, :env) == :test

  @impl true
  def mount(_params, _session, socket) do
    rows = demo_rows()

    if connected?(socket) and not test_env?(), do: :timer.send_interval(@tick_interval, :demo_tick)

    {:ok,
     socket
     |> assign(:demo_rows, rows)
     |> assign(:demo_state, rows)
     |> assign(:interaction_log, [])
     |> assign(:demo_cycle, 0)
     |> assign(:demo_dragging?, false)
     |> assign(:demo_row_ids, Tree.collect_ids(rows))
     |> assign(:demo_selected_ids, MapSet.new())
     |> assign(:demo_cursor, 0)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:row_click, fn row ->
        JS.push("demo:inspect", value: %{row_id: row.id})
      end)
      |> assign(:table_id, @table_dom_id)
      |> assign(:selection_label_id, "#{@table_dom_id}-selection-label")

    ~H"""
    <section aria-labelledby="rich-table-demo-heading" class="space-y-6">
      <.header class="mb-0">
        Rich Table Demo
        <:subtitle>
          Resize columns, drag headers or rows, and drop workloads into folders to see LiveView events stream in real time.
        </:subtitle>
      </.header>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <div class="card border border-base-300 bg-base-100 shadow-xl">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h3 id="rich-table-demo-heading" class="card-title text-base">
                  Environment inventory
                </h3>
                <p class="text-sm text-base-content/70">
                  Sample workloads so you can try every interaction.
                </p>
              </div>
              <span class="badge badge-ghost badge-sm">Demo</span>
            </div>

            <p id={@selection_label_id} class="mt-4 text-sm text-base-content/70">
              {selection_summary(@demo_selected_ids, length(@demo_row_ids))}
            </p>

            <.rich_table
              id={@table_id}
              rows={@demo_rows}
              row_click={@row_click}
              row_drop_event="demo:row_dropped"
              column_resize_event="demo:column_resized"
              column_order_event="demo:column_reordered"
              row_drag_event="demo:row_drag"
              selectable={true}
              selected_row_ids={MapSet.to_list(@demo_selected_ids)}
              selection_event="demo:selection_changed"
              selection_label_target={@selection_label_id}
              phx-update="ignore"
            >
              <:col :let={slot} id="name" label="Name" width={260}>
                <div class="flex flex-col">
                  <span class="text-sm font-semibold">{slot.row.name}</span>
                  <span class="text-xs opacity-70" data-row-field="description">
                    {slot.row.description}
                  </span>
                </div>
              </:col>
              <:col :let={slot} id="owner" label="Owner" width={160}>
                <span class="text-sm">{slot.row.owner}</span>
              </:col>
              <:col :let={slot} id="status" label="Status" width={140}>
                <span
                  class={[
                    "badge badge-sm text-xs tracking-tight",
                    status_badge_class(slot.row.status)
                  ]}
                  data-row-field="status"
                  data-status={slot.row.status}
                >
                  {status_label(slot.row.status)}
                </span>
              </:col>
              <:col :let={slot} id="updated" label="Updated" width={150}>
                <span class="text-sm" data-row-field="updated_at">{slot.row.updated_at}</span>
              </:col>
              <:action :let={slot}>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="demo:pin"
                  phx-value-id={slot.row_id}
                >
                  Pin
                </button>
              </:action>
            </.rich_table>
          </div>
        </div>

        <div class="card border border-base-300 bg-base-100 shadow-md">
          <div class="card-body">
            <h3 class="card-title text-base">
              Live event log
            </h3>
            <p class="text-sm text-base-content/70">
              Each interaction is pushed back to the LiveView so the server can persist user intent.
            </p>

            <ol class="mt-4 space-y-3 text-sm">
              <li
                :if={@interaction_log == []}
                class="rounded-lg border border-dashed border-base-300 px-4 py-3 text-base-content/70"
              >
                Try resizing a column, dragging a header, or dropping a row to see entries appear here.
              </li>
              <li
                :for={entry <- @interaction_log}
                class="rounded-lg border border-base-200 bg-base-200/40 px-4 py-3"
              >
                <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  {entry.timestamp}
                </div>
                <div class="font-semibold">{entry.title}</div>
                <div class="text-xs text-base-content/70">{entry.detail}</div>
              </li>
            </ol>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_info(:demo_tick, socket) do
    cycle = socket.assigns.demo_cycle + 1
    dragging? = socket.assigns.demo_dragging?

    if dragging? do
      {:noreply, assign(socket, :demo_cycle, cycle)}
    else
      ids = socket.assigns.demo_row_ids
      cursor = socket.assigns.demo_cursor
      {target_ids, next_cursor} = pulse_target_ids(ids, cursor, @pulse_chunk_size)

      {state, _changed?, diffs} =
        pulse_demo_rows(
          socket.assigns.demo_state,
          MapSet.new(target_ids),
          cycle,
          now_timestamp()
        )

      socket =
        socket
        |> assign(:demo_cycle, cycle)
        |> assign(:demo_cursor, next_cursor)
        |> assign(:demo_state, state)
        |> maybe_push_pulse(diffs)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("demo:row_dropped", params, socket) do
    detail = describe_row_drop(params)

    case Tree.apply_drop(socket.assigns.demo_state, params) do
      {:ok, updated_rows} ->
        new_row_ids = Tree.collect_ids(updated_rows)

        selection =
          socket.assigns.demo_selected_ids
          |> MapSet.intersection(MapSet.new(new_row_ids))

        socket =
          socket
          |> assign(:demo_rows, updated_rows)
          |> assign(:demo_state, updated_rows)
          |> assign(:demo_row_ids, new_row_ids)
          |> assign(:demo_selected_ids, selection)
          |> append_log("Row dropped", detail)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, append_log(socket, "Drop ignored", reason)}
    end
  end

  @impl true
  def handle_event("demo:column_resized", %{"column_id" => column_id, "width" => width}, socket) do
    width_label =
      width
      |> normalize_width()
      |> then(&"#{&1}px")

    detail = "Column “#{column_id}” locked to #{width_label}"
    {:noreply, append_log(socket, "Column resized", detail)}
  end

  @impl true
  def handle_event("demo:column_reordered", %{"order" => order}, socket) do
    detail = Enum.join(order, " → ")
    {:noreply, append_log(socket, "Columns reordered", detail)}
  end

  @impl true
  def handle_event("demo:selection_changed", %{"selected_ids" => ids}, socket) do
    valid_ids = MapSet.new(socket.assigns.demo_row_ids)

    selection =
      ids
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.intersection(valid_ids)

    {:noreply, assign(socket, :demo_selected_ids, selection)}
  end

  @impl true
  def handle_event("demo:inspect", %{"row_id" => row_id}, socket) do
    {:noreply, append_log(socket, "Row clicked", "Opened inspector for #{row_id}")}
  end

  @impl true
  def handle_event("demo:pin", %{"id" => row_id}, socket) do
    {:noreply, append_log(socket, "Pin toggled", "Toggled quick access for #{row_id}")}
  end

  @impl true
  def handle_event("demo:row_drag", %{"state" => "start"} = params, socket) do
    {:noreply, assign(socket, :demo_dragging?, true) |> maybe_log_drag(params)}
  end

  def handle_event("demo:row_drag", %{"state" => "end"} = params, socket) do
    {:noreply, assign(socket, :demo_dragging?, false) |> maybe_log_drag(params)}
  end

  defp maybe_log_drag(socket, %{"state" => "start", "row_id" => row_id}) do
    append_log(socket, "Row drag start", "Picked up #{row_id}")
  end

  defp maybe_log_drag(socket, %{"state" => "end", "row_id" => row_id}) do
    append_log(socket, "Row drag end", "Released #{row_id || "unknown"}")
  end

  defp maybe_log_drag(socket, _params), do: socket

  defp append_log(socket, title, detail) do
    entry = %{
      title: title,
      detail: detail,
      timestamp: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
    }

    logs =
      [entry | socket.assigns.interaction_log]
      |> Enum.take(6)

    assign(socket, :interaction_log, logs)
  end

  defp normalize_width(width) when is_binary(width) do
    Parse.integer_or_default(width, width)
  end

  defp normalize_width(width) when is_number(width), do: round(width)
  defp normalize_width(width), do: width

  defp describe_row_drop(%{"source_ids" => [_ | _] = ids} = params) do
    primary = List.first(ids)
    base = describe_row_drop(Map.put(params, "source_id", primary))

    case length(ids) do
      1 -> base
      count -> base <> " (#{count} rows)"
    end
  end

  defp describe_row_drop(%{"action" => "into", "source_id" => source, "target_id" => target}) do
    "Moved #{source} into #{target}"
  end

  defp describe_row_drop(%{"action" => "before", "source_id" => source, "target_id" => target}) do
    "Placed #{source} before #{target}"
  end

  defp describe_row_drop(%{"action" => "after", "source_id" => source, "target_id" => target}) do
    "Placed #{source} after #{target}"
  end

  defp describe_row_drop(%{"action" => "end", "source_id" => source}) do
    "Moved #{source} to the bottom of the list"
  end

  defp describe_row_drop(params) do
    "Reordered #{Map.get(params, "source_id", "unknown row")}"
  end

  defp status_badge_class(:healthy), do: "badge-success"
  defp status_badge_class("healthy"), do: status_badge_class(:healthy)
  defp status_badge_class(:warning), do: "badge-warning"
  defp status_badge_class("warning"), do: status_badge_class(:warning)
  defp status_badge_class(:offline), do: "badge-error"
  defp status_badge_class("offline"), do: status_badge_class(:offline)
  defp status_badge_class(_), do: "badge-neutral"

  defp status_label(:healthy), do: "Healthy"
  defp status_label(:warning), do: "Warning"
  defp status_label(:offline), do: "Offline"
  defp status_label(value) when is_binary(value), do: String.capitalize(value)
  defp status_label(_), do: "Unknown"

  @stress_group_count 32
  @stress_children_per_group 16

  defp demo_rows do
    if test_env?() do
      base_demo_rows()
    else
      base_demo_rows() ++ stress_rows()
    end
  end

  defp base_demo_rows do
    [
      %{
        id: "production",
        type: :folder,
        name: "Production cluster",
        owner: "Platform Ops",
        status: :healthy,
        updated_at: "Mar 8 · 09:24",
        description: "Critical workloads and SLO-backed services",
        children: [
          %{
            id: "orders-api",
            name: "Orders API",
            owner: "Commerce",
            status: :healthy,
            updated_at: "09:02",
            description: "Handles order lifecycle events"
          },
          %{
            id: "ledger-stream",
            name: "Ledger stream",
            owner: "FinOps",
            status: :warning,
            updated_at: "08:41",
            description: "Backlog on shard east-2"
          }
        ]
      },
      %{
        id: "staging",
        type: :folder,
        name: "Staging",
        owner: "QA Guild",
        status: :warning,
        updated_at: "Mar 7 · 21:18",
        description: "Pre-release validation environments",
        children: [
          %{
            id: "ui-preview",
            name: "UI preview",
            owner: "Design Systems",
            status: :healthy,
            updated_at: "Yesterday",
            description: "Latest Tailwind builds"
          },
          %{
            id: "api-contract",
            name: "Contract tests",
            owner: "QA Guild",
            status: :offline,
            updated_at: "2 days ago",
            description: "Suite paused while updating fixtures"
          }
        ]
      },
      %{
        id: "analytics",
        name: "Analytics ETL",
        owner: "Data Platform",
        status: :offline,
        updated_at: "Mar 5 · 23:10",
        description: "Nightly ingestion paused for schema change"
      }
    ]
  end

  defp stress_rows do
    for group <- 1..@stress_group_count do
      %{
        id: "stress-group-#{group}",
        type: :folder,
        name: "Cluster #{group}",
        owner: "EnvOps #{rem(group, 5) + 1}",
        status: cycle_status(group),
        updated_at: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC"),
        description: "Synthetic workloads for demo #{group}",
        children:
          for workload <- 1..@stress_children_per_group do
            %{
              id: "cluster-#{group}-workload-#{workload}",
              name: "Workload #{group}.#{workload}",
              owner: "Team #{rem(group + workload, 9) + 1}",
              status: cycle_status(group + workload),
              updated_at: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC"),
              description: "Live sample #{group * workload}"
            }
          end
      }
    end
  end

  defp pulse_demo_rows(rows, target_ids, cycle, timestamp) do
    {updated_rows, {changed?, diffs}} =
      Enum.map_reduce(rows, {false, []}, fn row, {changed?, diffs} ->
        {new_row, row_changed?, row_diffs} = pulse_demo_row(row, target_ids, cycle, timestamp)
        {new_row, {changed? or row_changed?, row_diffs ++ diffs}}
      end)

    if changed? do
      {updated_rows, true, Enum.reverse(diffs)}
    else
      {rows, false, []}
    end
  end

  defp pulse_demo_row(nil, _target_ids, _cycle, _timestamp), do: {nil, false, []}

  defp pulse_demo_row(row, target_ids, cycle, timestamp) do
    children = Map.get(row, :children)

    {new_children, children_changed?, child_diffs} =
      if is_list(children) do
        pulse_demo_rows(children, target_ids, cycle, timestamp)
      else
        {children, false, []}
      end

    row_targeted? = MapSet.member?(target_ids, row.id)

    cond do
      row_targeted? ->
        row_with_children = Map.put(row, :children, new_children)
        {updated_row, row_diff} = apply_row_pulse(row_with_children, cycle, timestamp)
        {updated_row, true, [row_diff | child_diffs]}

      children_changed? ->
        {Map.put(row, :children, new_children), true, child_diffs}

      true ->
        {row, false, child_diffs}
    end
  end

  defp apply_row_pulse(row, cycle, timestamp) do
    hash = :erlang.phash2({row.id, cycle}, 10_000)
    status = cycle_status(cycle + hash)

    description =
      case Map.get(row, :children) do
        list when is_list(list) and list != [] -> Map.get(row, :description)
        _ -> "Live sample #{hash}"
      end

    updated_row =
      row
      |> Map.put(:status, status)
      |> Map.put(:updated_at, timestamp)
      |> Map.put(:description, description)

    diff = %{
      id: row.id,
      status: status,
      status_label: status_label(status),
      status_class: status_badge_class(status),
      description: description,
      updated_at: timestamp
    }

    {updated_row, diff}
  end

  defp pulse_target_ids([], _cursor, _chunk), do: {[], 0}

  defp pulse_target_ids(ids, cursor, chunk) do
    total = length(ids)
    chunk_size = min(chunk, total)
    start = rem(max(cursor, 0), total)
    {head, tail} = Enum.split(ids, start)
    ordered = tail ++ head
    selection = Enum.take(ordered, chunk_size)
    next_cursor = rem(start + chunk_size, total)
    {selection, next_cursor}
  end

  defp now_timestamp do
    Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
  end

  defp maybe_push_pulse(socket, []), do: socket

  defp maybe_push_pulse(socket, rows) do
    push_event(socket, "rich-table:pulse", %{target: @table_dom_id, rows: rows})
  end

  defp cycle_status(cycle) do
    idx = rem(cycle, length(@status_cycle))
    Enum.at(@status_cycle, idx)
  end

  defp selection_summary(selection, total) do
    set = selection || MapSet.new()
    count = MapSet.size(set)

    cond do
      count == 0 -> "No rows selected"
      total > 0 and count == total -> "All #{total} rows selected"
      true -> "#{count} #{pluralize_rows(count)} selected"
    end
  end

  defp pluralize_rows(1), do: "row"
  defp pluralize_rows(_), do: "rows"
end
