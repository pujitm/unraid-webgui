defmodule UnraidWeb.CardComponents do
  @moduledoc ~S"""
  Composable card primitives for building card-based UIs.

  This module provides building blocks for card layouts with support for:
  - Hierarchical tree structures (folders containing items)
  - Item-level expansion (showing details within a card)
  - Selection with checkboxes
  - Drag & drop reordering

  ## Architecture

  The system is split into two layers:

  1. **Container** (`card_list`) - Handles tree traversal, state management,
     and coordinates the JS hook for drag/drop and selection.

  2. **Primitives** - Stateless components for building card content:
     - `card` - Visual card wrapper
     - `card_row` - Horizontal layout for card content
     - `card_expanded` - Container for expanded content
     - `expand_toggle` - Button to expand/collapse
     - `select_checkbox` - Selection checkbox
     - `drag_handle` - Drag handle for reordering
     - `card_avatar` - Avatar with icon/initials
     - `card_metric` - Label/value pair
     - `card_status` - Status badge with colored dot

  ## Basic Usage

      <.card_list
        id="items"
        rows={@items}
        row_id={fn item -> item.id end}
        expanded_ids={@expanded_ids}
        selected_ids={@selected_ids}
        on_expand="toggle_expand"
        on_select="selection_changed"
        on_drop="row_dropped"
      >
        <:row :let={slot}>
          <.card selected={slot.selected}>
            <.card_row>
              <.expand_toggle expanded={slot.expanded} has_content={true} />
              <.select_checkbox selected={slot.selected} />
              <.drag_handle />
              <div class="flex-1">{slot.row.name}</div>
            </.card_row>
            <.card_expanded :if={slot.expanded}>
              <p>Expanded content here</p>
            </.card_expanded>
          </.card>
        </:row>
      </.card_list>

  ## Heterogeneous Rows

  Use pattern matching in the slot to render different row types:

      <:row :let={slot}>
        <%= case slot.row.type do %>
          <% :folder -> %>
            <.folder_row row={slot.row} expanded={slot.expanded} />
          <% :item -> %>
            <.item_row row={slot.row} expanded={slot.expanded} selected={slot.selected} />
        <% end %>
      </:row>
  """

  use Phoenix.Component
  use Gettext, backend: UnraidWeb.Gettext

  import UnraidWeb.CoreComponents, only: [icon: 1]

  # ===========================================================================
  # Card List Container
  # ===========================================================================

  @doc """
  Container component that manages a list of cards with tree structure support.

  Handles:
  - Flattening nested rows (via `:children` key)
  - Tracking expanded/selected state per row
  - Coordinating with JS hook for drag/drop and selection

  ## Attributes

  - `id` - Required. Unique ID for the component.
  - `rows` - Required. List of row data. Rows with `:children` key are treated as parents.
  - `row_id` - Function to extract unique ID from each row. Defaults to `& &1.id`.
  - `expanded_ids` - List of IDs that are currently expanded.
  - `selected_ids` - List of IDs that are currently selected.
  - `on_expand` - Event name for expand/collapse. Receives `%{id: id, expanded: bool}`.
  - `on_select` - Event name for selection changes. Receives `%{selected_ids: [...]}`.
  - `on_drop` - Event name for drag/drop. Receives drop event params.
  - `on_drag` - Event name for drag lifecycle (start/end).
  - `selectable` - Enable selection checkboxes. Default false.
  - `draggable` - Enable drag/drop. Default true.
  - `class` - Additional CSS classes.

  ## Slots

  - `row` - Required. Renders each row. Receives slot with:
    - `row` - The original row data
    - `id` - The row's unique ID
    - `depth` - Nesting depth (0 for top-level)
    - `parent_id` - ID of parent row, or nil
    - `expanded` - Whether this row is expanded
    - `selected` - Whether this row is selected
    - `has_children` - Whether this row has children
    - `type` - `:folder` or `:item`

  - `col_header` - Optional. Column headers displayed above cards.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :expanded_ids, :list, default: []
  attr :selected_ids, :list, default: []
  attr :on_expand, :string, default: nil
  attr :on_select, :string, default: nil
  attr :on_drop, :string, default: "card_list:row_dropped"
  attr :on_drag, :string, default: nil
  attr :selectable, :boolean, default: false
  attr :draggable, :boolean, default: true
  attr :class, :string, default: nil

  slot :row, required: true

  slot :col_header do
    attr :class, :string
  end

  def card_list(assigns) do
    row_id_fun = build_row_id_fun(assigns.row_id)
    expanded_set = MapSet.new(List.wrap(assigns.expanded_ids))
    selected_set = MapSet.new(List.wrap(assigns.selected_ids))

    # Flatten tree structure, filtering out collapsed children
    flat_rows =
      assigns.rows
      |> List.wrap()
      |> flatten_tree(row_id_fun, expanded_set, selected_set, 0, nil)

    # Build selection payload for JS hook
    sorted_selection = selected_set |> MapSet.to_list() |> Enum.sort()

    selection_payload =
      if assigns.selectable do
        Jason.encode!(sorted_selection)
      else
        nil
      end

    selection_hash =
      if assigns.selectable do
        sorted_selection |> :erlang.phash2() |> Integer.to_string()
      else
        nil
      end

    assigns =
      assigns
      |> assign(:flat_rows, flat_rows)
      |> assign(:container_id, "#{assigns.id}-container")
      |> assign(:selection_payload, selection_payload)
      |> assign(:selection_hash, selection_hash)
      |> assign(:has_col_headers?, assigns.col_header != [])

    ~H"""
    <div
      id={@id}
      class={["card-list", @class]}
      phx-hook="CardList"
      data-row-drop-event={@on_drop}
      data-row-drag-event={@on_drag}
      data-expand-event={@on_expand}
      data-selectable={@selectable && "true"}
      data-selection-event={@selectable && @on_select}
      data-selected-rows={@selectable && @selection_payload}
      data-selection-hash={@selectable && @selection_hash}
      data-draggable={@draggable && "true"}
    >
      <%!-- Column Headers --%>
      <div :if={@has_col_headers?} class="card-list__col-headers">
        <div :for={col_header <- @col_header} class={["card-list__col-header", col_header[:class]]}>
          {render_slot(col_header)}
        </div>
      </div>

      <%!-- Cards Container --%>
      <div id={@container_id} data-role="card-list-container" class="card-list__container">
        <div
          :for={row_data <- @flat_rows}
          :if={row_data.visible}
          id={"#{@id}-row-#{row_data.id}"}
          class="card-list__row"
          data-row-id={row_data.id}
          data-depth={row_data.depth}
          data-parent-id={row_data.parent_id}
          data-has-children={row_data.has_children && "true"}
          data-expanded={row_data.expanded && "true"}
          data-selected={row_data.selected && "true"}
          data-type={row_data.type}
          style={"--card-depth: #{row_data.depth};"}
        >
          {render_slot(@row, row_data)}
        </div>
      </div>
    </div>
    """
  end

  # Flatten tree structure into a list of rows with metadata
  defp flatten_tree(rows, row_id_fun, expanded_set, selected_set, depth, parent_id) do
    rows
    |> Enum.flat_map(fn row ->
      row_id = row_id_fun.(row)
      children = get_children(row)
      has_children = children != []
      is_expanded = MapSet.member?(expanded_set, row_id)
      is_selected = MapSet.member?(selected_set, row_id)
      row_type = if has_children, do: get_type(row, :folder), else: get_type(row, :item)

      current = %{
        row: row,
        id: row_id,
        depth: depth,
        parent_id: parent_id,
        has_children: has_children,
        expanded: is_expanded,
        selected: is_selected,
        type: row_type,
        visible: true
      }

      # Only include children if parent is expanded
      child_rows =
        if has_children and is_expanded do
          flatten_tree(children, row_id_fun, expanded_set, selected_set, depth + 1, row_id)
        else
          []
        end

      [current | child_rows]
    end)
  end

  defp get_children(row) do
    (Map.get(row, :children) || Map.get(row, "children") || [])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp get_type(row, default) do
    type = Map.get(row, :type) || Map.get(row, "type")

    case type do
      :folder -> :folder
      "folder" -> :folder
      :item -> :item
      "item" -> :item
      _ -> default
    end
  end

  defp build_row_id_fun(nil) do
    fn row ->
      Map.get(row, :id) || Map.get(row, "id") ||
        raise ArgumentError, "card_list requires rows to have an :id key or a custom :row_id function"
    end
  end

  defp build_row_id_fun(fun) when is_function(fun, 1), do: fun

  defp build_row_id_fun(field) when is_atom(field) or is_binary(field) do
    fn row -> Map.get(row, field) end
  end

  # ===========================================================================
  # Card Primitives
  # ===========================================================================

  @doc """
  Visual card wrapper with optional selected state.

  ## Attributes

  - `selected` - Whether the card is selected
  - `variant` - Visual variant: `:default`, `:folder`
  - `class` - Additional CSS classes

  ## Slots

  - `inner_block` - Card content
  """
  attr :selected, :boolean, default: false
  attr :variant, :atom, default: :default
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={[
      "card border border-base-300 bg-base-100",
      @selected && "card--selected ring-2 ring-primary/20 border-primary/30",
      @variant == :folder && "card--folder",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Horizontal layout container for card content.

  Use this for the main row content. Provides consistent padding and flex layout.

  ## Attributes

  - `class` - Additional CSS classes

  ## Slots

  - `inner_block` - Row content
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card_row(assigns) do
    ~H"""
    <div class={["card-row flex items-center gap-3 p-4", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Container for expanded content shown below the card row.

  ## Attributes

  - `class` - Additional CSS classes

  ## Slots

  - `inner_block` - Expanded content
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card_expanded(assigns) do
    ~H"""
    <div class={["card-expanded border-t border-base-300 bg-base-200/30 p-4", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Expand/collapse toggle button.

  ## Attributes

  - `expanded` - Current expanded state
  - `has_content` - Whether there is content to expand (shows toggle only if true)
  - `class` - Additional CSS classes
  """
  attr :expanded, :boolean, default: false
  attr :has_content, :boolean, default: true
  attr :class, :string, default: nil

  def expand_toggle(assigns) do
    ~H"""
    <button
      :if={@has_content}
      type="button"
      class={[
        "expand-toggle flex-shrink-0 w-6 h-6 inline-flex items-center justify-center",
        "rounded-md bg-transparent border-none cursor-pointer",
        "text-base-content/50 hover:text-base-content hover:bg-base-content/10",
        "transition-colors duration-150",
        @class
      ]}
      data-expand-toggle="true"
      aria-label={if @expanded, do: gettext("Collapse"), else: gettext("Expand")}
      aria-expanded={to_string(@expanded)}
    >
      <.icon name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"} class="w-5 h-5" />
    </button>
    <div :if={not @has_content} class="w-6 flex-shrink-0"></div>
    """
  end

  @doc """
  Selection checkbox.

  ## Attributes

  - `selected` - Current selected state
  - `class` - Additional CSS classes
  """
  attr :selected, :boolean, default: false
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  def select_checkbox(assigns) do
    ~H"""
    <input
      type="checkbox"
      class={[
        "select-checkbox w-4 h-4 flex-shrink-0 cursor-pointer",
        "accent-primary rounded",
        @class
      ]}
      data-selection-control="card"
      data-row-id={@id}
      checked={@selected}
      aria-label={gettext("Select row")}
    />
    """
  end

  @doc """
  Drag handle for reordering.

  ## Attributes

  - `class` - Additional CSS classes
  """
  attr :class, :string, default: nil

  def drag_handle(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "drag-handle flex-shrink-0 w-5 h-5 rounded-full border border-transparent",
        "bg-transparent inline-flex items-center justify-center",
        "cursor-grab touch-none select-none",
        "text-base-content/35 hover:text-base-content/70 hover:bg-base-content/8 hover:border-base-content/15",
        "active:cursor-grabbing transition-colors duration-150",
        @class
      ]}
      data-drag-handle="true"
      aria-label={gettext("Reorder")}
      tabindex="-1"
    >
      <span class="w-[0.45rem] h-[0.45rem] rounded-sm border border-dashed border-current opacity-80" aria-hidden="true"></span>
    </button>
    """
  end

  @doc """
  Avatar with optional icon or initials fallback.

  ## Attributes

  - `icon` - URL to icon image
  - `name` - Name to derive initials from
  - `class` - Additional CSS classes
  """
  attr :icon, :string, default: nil
  attr :name, :string, default: nil
  attr :class, :string, default: nil

  def card_avatar(assigns) do
    initials = if assigns.name, do: get_initials(assigns.name), else: "?"
    assigns = assign(assigns, :initials, initials)

    ~H"""
    <div class={[
      "card-avatar w-10 h-10 rounded-lg bg-base-200 flex items-center justify-center overflow-hidden flex-shrink-0",
      @class
    ]}>
      <img
        :if={@icon}
        src={@icon}
        class="w-full h-full object-contain"
        onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
      />
      <span
        class={["text-xs font-semibold text-base-content/50", @icon && "hidden"]}
        style={@icon && "display: none"}
      >
        {@initials}
      </span>
    </div>
    """
  end

  @doc """
  Metric display with label and value.

  ## Attributes

  - `label` - Metric label
  - `value` - Metric value
  - `class` - Additional CSS classes
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: nil

  def card_metric(assigns) do
    ~H"""
    <div class={["card-metric flex flex-col items-center min-w-12", @class]}>
      <span class="text-[0.65rem] uppercase tracking-wide text-base-content/50">{@label}</span>
      <span class="font-mono text-sm">{format_metric_value(@value)}</span>
    </div>
    """
  end

  @doc """
  Status badge with colored dot indicator.

  ## Attributes

  - `state` - Status atom: `:running`, `:stopped`, `:paused`, `:restarting`, `:created`
  - `class` - Additional CSS classes
  """
  attr :state, :atom, required: true
  attr :class, :string, default: nil

  def card_status(assigns) do
    ~H"""
    <span
      class={[
        "card-status inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full",
        "text-xs font-medium uppercase tracking-wide border",
        status_classes(@state),
        @class
      ]}
      data-card-field="state"
    >
      <span class={["w-2 h-2 rounded-full flex-shrink-0", status_dot_class(@state)]}></span>
      {status_label(@state)}
    </span>
    """
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp get_initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s\-_]+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp get_initials(_), do: "?"

  defp format_metric_value(nil), do: "—"
  defp format_metric_value(value) when is_binary(value), do: value
  defp format_metric_value(value) when is_number(value), do: to_string(value)
  defp format_metric_value(value), do: inspect(value)

  defp status_classes(:running), do: "text-success bg-success/10 border-success/20"
  defp status_classes(:stopped), do: "text-error bg-error/10 border-error/20"
  defp status_classes(:paused), do: "text-warning bg-warning/10 border-warning/20"
  defp status_classes(:restarting), do: "text-info bg-info/10 border-info/20"
  defp status_classes(_), do: "text-base-content/60 bg-base-content/8 border-base-content/15"

  defp status_dot_class(:running), do: "bg-success"
  defp status_dot_class(:stopped), do: "bg-error"
  defp status_dot_class(:paused), do: "bg-warning"
  defp status_dot_class(:restarting), do: "bg-info"
  defp status_dot_class(_), do: "bg-base-content/40"

  defp status_label(:running), do: "Running"
  defp status_label(:paused), do: "Paused"
  defp status_label(:stopped), do: "Stopped"
  defp status_label(:restarting), do: "Restarting"
  defp status_label(:created), do: "Created"
  defp status_label(:dead), do: "Dead"
  defp status_label(_), do: "Unknown"
end
