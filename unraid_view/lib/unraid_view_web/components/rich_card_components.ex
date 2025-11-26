defmodule UnraidViewWeb.RichCardComponents do
  @moduledoc ~S"""
  Card-based data display component with drag & drop support.

  This component provides a card-based alternative to `RichTableComponents` for
  displaying hierarchical data. Cards support expand/collapse for nested children,
  selection, and the same drag & drop semantics (before/after/into).

  ## Basic usage

      <.rich_card
        id="containers-cards"
        rows={@containers}
        row_id={fn c -> c.id end}
        row_drop_event="containers:row_dropped"
        selectable={true}
      >
        <:header :let={slot}>
          <div class="flex items-center gap-3">
            <.card_avatar icon={slot.row.icon} name={slot.row.name} />
            <div>
              <div class="font-semibold">{slot.row.name}</div>
              <div class="text-sm opacity-60">{slot.row.description}</div>
            </div>
          </div>
        </:header>

        <:metrics :let={slot}>
          <.card_metric label="CPU" value={slot.row.cpu} />
          <.card_metric label="RAM" value={slot.row.ram} />
        </:metrics>

        <:status :let={slot}>
          <.card_status state={slot.row.state} />
        </:status>

        <:action :let={slot}>
          <button phx-click="start" phx-value-id={slot.row.id}>Start</button>
        </:action>
      </.rich_card>

  ## Nesting

  Rows with a `:children` key are rendered as expandable cards. Child cards are
  visually indented based on their depth level.

  ## Drag & Drop

  The component uses the same drag & drop model as `RichTableComponents`:
  - Drag via the handle on the left side of the card
  - Drop zones: before (top 25%), into (middle 50%), after (bottom 25%)
  - Touch support for mobile devices
  - Multi-select drag when selection is enabled
  """
  use Phoenix.Component
  use Gettext, backend: UnraidViewWeb.Gettext

  import UnraidViewWeb.CoreComponents, only: [icon: 1]

  @default_row_drop_event "rich_card:row_dropped"

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)

  attr(:row_id, :any,
    default: nil,
    doc: "function, atom, or string used to derive a unique row identifier"
  )

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "transformation applied to each row before it is passed to slots"
  )

  attr(:row_drop_event, :string, default: @default_row_drop_event)
  attr(:row_drag_event, :string, default: nil)
  attr(:selectable, :boolean, default: false)
  attr(:selected_row_ids, :list, default: [])
  attr(:selection_event, :string, default: nil)
  attr(:expanded_ids, :list, default: [], doc: "List of card IDs that are currently expanded")
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  slot :header, required: true do
    attr(:class, :string)
  end

  slot :metrics do
    attr(:class, :string)
  end

  slot :status do
    attr(:class, :string)
  end

  slot(:action, doc: "Action buttons/menus for each card")

  slot :col_header do
    attr(:id, :string)
    attr(:class, :string)
  end

  def rich_card(assigns) do
    row_id_fun = build_row_id_fun(assigns.row_id)

    selected_ids =
      if assigns.selectable do
        assigns.selected_row_ids |> List.wrap() |> MapSet.new()
      else
        MapSet.new()
      end

    expanded_ids = assigns.expanded_ids |> List.wrap() |> MapSet.new()

    flat_rows =
      flatten_rows(assigns.rows, row_id_fun, assigns.row_item)
      |> Enum.map(fn row ->
        row
        |> Map.put(:selected, MapSet.member?(selected_ids, row.id))
        |> Map.put(:expanded, MapSet.member?(expanded_ids, row.id))
      end)

    sorted_selection = selected_ids |> MapSet.to_list() |> Enum.sort()

    selection_payload =
      if assigns.selectable do
        Jason.encode!(sorted_selection)
      else
        nil
      end

    selection_hash =
      if assigns.selectable do
        sorted_selection
        |> :erlang.phash2()
        |> Integer.to_string()
      else
        nil
      end

    assigns =
      assigns
      |> assign(:row_id_fun, row_id_fun)
      |> assign(:flat_rows, flat_rows)
      |> assign(:card_container_id, "#{assigns.id}-cards")
      |> assign(:has_actions?, assigns.action != [])
      |> assign(:has_metrics?, assigns.metrics != [])
      |> assign(:has_status?, assigns.status != [])
      |> assign(:has_col_headers?, assigns.col_header != [])
      |> assign(:selectable?, assigns.selectable)
      |> assign(:selection_payload, selection_payload)
      |> assign(:selection_hash, selection_hash)
      |> assign(:rest_attrs, clean_rest(assigns.rest))

    ~H"""
    <div
      id={@id}
      class={[
        "rich-card-list",
        @class
      ]}
      phx-hook="RichCard"
      data-row-drop-event={@row_drop_event}
      data-row-drag-event={@row_drag_event}
      data-selectable={@selectable? && "true"}
      data-selection-event={@selectable? && @selection_event}
      data-selected-rows={@selectable? && @selection_payload}
      data-selection-hash={@selectable? && @selection_hash}
      {@rest_attrs}
    >
      <%!-- Column Headers --%>
      <div :if={@has_col_headers?} class="rich-card__col-headers">
        <%= for col_header <- @col_header do %>
          <div class={["rich-card__col-header", col_header[:class]]}>
            {render_slot(col_header)}
          </div>
        <% end %>
      </div>

      <div id={@card_container_id} data-role="rich-card-container" class="rich-card__container">
        <.card
          :for={row <- @flat_rows}
          id={"#{@id}-card-#{row.id}"}
          row={row}
          header={@header}
          metrics={@metrics}
          status={@status}
          action={@action}
          selectable?={@selectable?}
          has_actions?={@has_actions?}
          has_metrics?={@has_metrics?}
          has_status?={@has_status?}
        />
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:row, :map, required: true)
  attr(:header, :list, required: true)
  attr(:metrics, :list, default: [])
  attr(:status, :list, default: [])
  attr(:action, :list, default: [])
  attr(:selectable?, :boolean, default: false)
  attr(:has_actions?, :boolean, default: false)
  attr(:has_metrics?, :boolean, default: false)
  attr(:has_status?, :boolean, default: false)

  defp card(assigns) do
    ~H"""
    <div
      id={@id}
      class={card_classes(@row)}
      data-card-id={@row.id}
      data-depth={@row.depth}
      data-parent-id={@row.parent_id}
      data-draggable={@row.draggable}
      data-droppable={@row.droppable}
      data-selected={@row.selected && "true"}
      data-expanded={@row.expanded && "true"}
      data-has-children={@row.has_children && "true"}
      style={indent_style(@row.depth)}
    >
      <div class="rich-card__inner">
        <%!-- Expand/Collapse Toggle (only shown if has children) --%>
        <button
          :if={@row.has_children}
          type="button"
          class="rich-card__expand-toggle"
          data-expand-toggle="true"
          aria-label={if @row.expanded, do: gettext("Collapse"), else: gettext("Expand")}
          aria-expanded={to_string(@row.expanded)}
        >
          <.icon
            name={if @row.expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="w-5 h-5"
          />
        </button>

        <%!-- Selection Checkbox --%>
        <div :if={@selectable?} class="rich-card__selection">
          <input
            type="checkbox"
            class="rich-card__selection-checkbox"
            data-selection-control="card"
            data-card-id={@row.id}
            checked={@row.selected}
            aria-label={gettext("Select %{row}", row: card_selection_label(@row.presented))}
          />
        </div>

        <%!-- Drag Handle --%>
        <button
          type="button"
          class="rich-card__drag-handle"
          data-card-handle="true"
          aria-label={gettext("Reorder card")}
          tabindex="-1"
        >
          <span aria-hidden="true"></span>
        </button>

        <%!-- Header Content --%>
        <div class="rich-card__header">
          <%= for header <- @header do %>
            {render_slot(header, %{
              row: @row.presented,
              depth: @row.depth,
              card_id: @row.id,
              expanded: @row.expanded
            })}
          <% end %>
        </div>

        <%!-- Metrics --%>
        <div :if={@has_metrics?} class="rich-card__metrics">
          <%= for metric <- @metrics do %>
            {render_slot(metric, %{
              row: @row.presented,
              depth: @row.depth,
              card_id: @row.id
            })}
          <% end %>
        </div>

        <%!-- Status --%>
        <div :if={@has_status?} class="rich-card__status">
          <%= for status <- @status do %>
            {render_slot(status, %{
              row: @row.presented,
              depth: @row.depth,
              card_id: @row.id
            })}
          <% end %>
        </div>

        <%!-- Actions --%>
        <div :if={@has_actions?} class="rich-card__actions">
          <%= for action <- @action do %>
            {render_slot(action, %{row: @row.presented, depth: @row.depth, card_id: @row.id})}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper Components
  # ---------------------------------------------------------------------------

  @doc """
  Renders an avatar for a card, with optional icon or initials fallback.
  """
  attr(:icon, :string, default: nil)
  attr(:name, :string, default: nil)
  attr(:class, :string, default: nil)

  def card_avatar(assigns) do
    initials = if assigns.name, do: get_initials(assigns.name), else: "?"

    assigns = assign(assigns, :initials, initials)

    ~H"""
    <div class={["rich-card__avatar", @class]}>
      <img
        :if={@icon}
        src={@icon}
        class="w-full h-full object-contain"
        onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
      />
      <span
        class={["rich-card__avatar-fallback", @icon && "hidden"]}
        style={@icon && "display: none"}
      >
        {@initials}
      </span>
    </div>
    """
  end

  @doc """
  Renders a single metric with label and value.
  """
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:class, :string, default: nil)

  def card_metric(assigns) do
    ~H"""
    <div class={["rich-card__metric", @class]}>
      <span class="rich-card__metric-label">{@label}</span>
      <span class="rich-card__metric-value">{format_metric_value(@value)}</span>
    </div>
    """
  end

  @doc """
  Renders a status badge with a colored dot indicator.
  """
  attr(:state, :atom, required: true)
  attr(:class, :string, default: nil)

  def card_status(assigns) do
    ~H"""
    <span class={["rich-card__status-badge", status_badge_class(@state), @class]} data-card-field="state">
      <span class="rich-card__status-dot"></span>
      {status_label(@state)}
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp card_classes(row) do
    [
      "rich-card",
      "card border border-base-300 bg-base-100",
      row.type == :folder && "rich-card--folder",
      row.selected && "rich-card--selected",
      row.has_children && !row.expanded && "rich-card--collapsed"
    ]
  end

  defp indent_style(depth) do
    "--rich-card-depth: #{depth};"
  end

  defp card_selection_label(row) do
    row_value(row, :name, "name") ||
      row_value(row, :title, "title") ||
      row_value(row, :id, "id") ||
      gettext("card")
  rescue
    _ -> gettext("card")
  end

  defp get_initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s\-_]+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp get_initials(_), do: "?"

  defp format_metric_value(nil), do: "—"
  defp format_metric_value(value) when is_binary(value), do: value
  defp format_metric_value(value) when is_number(value), do: to_string(value)
  defp format_metric_value(value), do: inspect(value)

  defp status_badge_class(:running), do: "rich-card__status-badge--running"
  defp status_badge_class(:paused), do: "rich-card__status-badge--paused"
  defp status_badge_class(:stopped), do: "rich-card__status-badge--stopped"
  defp status_badge_class(:restarting), do: "rich-card__status-badge--restarting"
  defp status_badge_class(:created), do: "rich-card__status-badge--default"
  defp status_badge_class(_), do: "rich-card__status-badge--default"

  defp status_label(:running), do: "Running"
  defp status_label(:paused), do: "Paused"
  defp status_label(:stopped), do: "Stopped"
  defp status_label(:restarting), do: "Restarting"
  defp status_label(:created), do: "Created"
  defp status_label(:dead), do: "Dead"
  defp status_label(_), do: "Unknown"

  defp build_row_id_fun(nil) do
    fn row ->
      Map.get(row, :id) || Map.get(row, "id") ||
        raise ArgumentError,
              "rich_card expects rows to include an :id key or a custom :row_id function"
    end
  end

  defp build_row_id_fun(fun) when is_function(fun, 1), do: fun

  defp build_row_id_fun(field) when is_atom(field) do
    fn row ->
      Map.get(row, field) ||
        raise ArgumentError,
              "rich_card could not find #{inspect(field)} on #{inspect(row)}"
    end
  end

  defp build_row_id_fun(field) when is_binary(field) do
    fn row ->
      Map.get(row, field) ||
        fetch_binary_atom_key(row, field) ||
        raise ArgumentError,
              "rich_card could not find #{inspect(field)} on #{inspect(row)}"
    end
  end

  defp fetch_binary_atom_key(row, field) do
    case safe_to_existing_atom(field) do
      nil -> nil
      atom -> Map.get(row, atom)
    end
  end

  defp safe_to_existing_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_to_existing_atom(_), do: nil

  defp flatten_rows(rows, row_id_fun, row_item) do
    rows
    |> List.wrap()
    |> Enum.flat_map(&flatten_row(&1, row_id_fun, row_item, 0, nil))
  end

  defp flatten_row(row, row_id_fun, row_item, depth, parent_id) do
    row_id = row_id_fun.(row)
    children = row_value(row, :children, "children") |> List.wrap()
    has_children = children != []

    current = %{
      id: row_id,
      original: row,
      presented: row_item.(row),
      depth: depth,
      parent_id: parent_id,
      type: normalize_type(row_value(row, :type, "type")),
      draggable: normalize_boolean(row_value(row, :draggable, "draggable"), true),
      droppable: normalize_boolean(row_value(row, :droppable, "droppable"), true),
      has_children: has_children
    }

    child_rows =
      children
      |> Enum.flat_map(&flatten_row(&1, row_id_fun, row_item, depth + 1, row_id))

    [current | child_rows]
  end

  defp row_value(row, atom_key, string_key) do
    cond do
      is_struct(row) -> Map.get(row, atom_key)
      is_map(row) -> Map.get(row, atom_key) || Map.get(row, string_key)
      true -> nil
    end
  rescue
    _ -> Map.get(row, string_key)
  end

  defp normalize_type(:folder), do: :folder
  defp normalize_type("folder"), do: :folder
  defp normalize_type(_), do: :item

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(nil, default), do: default

  defp normalize_boolean(value, default) when is_binary(value) do
    case String.downcase(value) do
      "false" -> false
      "true" -> true
      _ -> default
    end
  end

  defp normalize_boolean(_, default), do: default

  defp clean_rest(nil), do: %{}
  defp clean_rest(rest) when is_map(rest), do: Map.drop(rest, [:class, "class"])
  defp clean_rest(rest), do: rest |> Enum.into(%{}) |> Map.drop([:class, "class"])
end
