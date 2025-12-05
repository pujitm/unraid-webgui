defmodule UnraidWeb.RichTableComponents do
  @moduledoc ~S"""
  Interactive table primitives used to render folder-like hierarchies with
  client-side column resizing, column reordering, and advanced drag & drop
  semantics.

  The component is intentionally data-driven and renders whatever structure
  the parent LiveView (or LiveComponent) provides. All structural changes
  initiated on the client are reported back via LiveView events so that the
  server can persist and re-render the new state.

  ## Basic usage

      <.rich_table
        id="shares-table"
        rows={@rows}
        row_click={fn row -> JS.patch(~p"/shares/#{row.id}") end}
        row_drop_event="shares:row_dropped"
      >
        <:col :let={slot} id="name" label="Name" width={280}>
          <span class="font-semibold">{slot.row.name}</span>
        </:col>
        <:col :let={slot} id="comment" label="Comment">
          {slot.row.comment}
        </:col>
        <:col :let={slot} id="size" label="Size (GiB)" class="text-right" resizable={false}>
          <.formatted_size value={slot.row.size_gib} />
        </:col>
        <:action :let={action}>
          <button class="btn btn-ghost btn-xs" phx-click="open" phx-value-id={action.row.id}>
            Details
          </button>
        </:action>
      </.rich_table>

  Rows are plain maps (or structs) that may include nested `:children` lists to
  represent folders. By default every row is draggable and droppable; you can
  toggle those behaviours per row by setting `:draggable` / `:droppable` keys.
  Provide `row_drop_event`, `column_resize_event`, `column_order_event`, and/or
  `row_drag_event` assigns to persist user actions in your LiveView.

  ## High-frequency streams

  For extremely chatty datasets (container stats, stock tickers, etc.) you can
  keep the DOM stable and stream tiny diffs through a Phoenix push event. The
  `RichTableDemoLive` module demonstrates the pattern:

    * Render `<.rich_table ... phx-update="ignore">` so LiveView does not touch
      the table body on every tick.
    * Add semantic markers (e.g. `data-row-field="status"`) inside your columns
      so the default JS hook can find and patch the cells.
    * Periodically push a `"rich-table:pulse"` event that includes only the row
      ids and values that changed. Chunking the payload keeps both LiveView
      diffs and browser style recalculation small.
    * The built-in hook listens for those events and updates the DOM in place,
      keeping UX smooth while the LiveView still coordinates access control,
      drag/drop, and other server concerns.

  This hybrid approach lets you mix the convenience of LiveView with the
  responsiveness of client-side streaming when dealing with latency-sensitive,
  high-volume data (for example, tailing `docker stats --no-stream=false` and
  feeding the aggregate metrics into the table).
  """
  use Phoenix.Component
  use Gettext, backend: UnraidWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Unraid.Parse

  @default_row_drop_event "rich_table:row_dropped"
  @default_column_resize_event "rich_table:column_resized"
  @default_column_order_event "rich_table:column_reordered"

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

  attr(:row_click, :any, default: nil, doc: "optional callback returning a JS command per row")

  attr(:row_class, :any,
    default: nil,
    doc: "string or 1-arity function for conditional row classes"
  )

  attr(:row_indent, :integer, default: 20, doc: "pixel offset per nested level")
  attr(:row_drop_event, :string, default: @default_row_drop_event)
  attr(:column_resize_event, :string, default: @default_column_resize_event)
  attr(:column_order_event, :string, default: @default_column_order_event)
  attr(:row_drag_event, :string, default: nil)
  attr(:selectable, :boolean, default: false)
  attr(:selected_row_ids, :list, default: [])
  attr(:selection_event, :string, default: nil)
  attr(:selection_label_target, :string, default: nil)
  attr(:selection_label_strings, :map, default: %{})
  attr(:searchable, :boolean, default: false, doc: "Enable client-side fuzzy search")

  attr(:search_fields, :any,
    default: nil,
    doc: "Function returning list of searchable strings for a row"
  )

  attr(:class, :string, default: nil)
  attr(:rest, :global)

  slot :col, required: true do
    attr(:id, :string, required: true)
    attr(:label, :string, required: true)
    attr(:width, :integer)
    attr(:min_width, :integer)
    attr(:class, :string)
    attr(:resizable, :boolean)
    attr(:reorderable, :boolean)
  end

  slot(:action, doc: "Optional trailing column rendered as row-level actions")

  def rich_table(assigns) do
    row_id_fun = build_row_id_fun(assigns.row_id)
    column_config = Enum.map(assigns.col, &column_config/1)
    zipped_columns = Enum.zip(assigns.col, column_config)

    selected_ids =
      if assigns.selectable do
        assigns.selected_row_ids |> List.wrap() |> MapSet.new()
      else
        MapSet.new()
      end

    flat_rows =
      flatten_rows(assigns.rows, row_id_fun, assigns.row_item)
      |> Enum.map(fn row ->
        Map.put(row, :selected, MapSet.member?(selected_ids, row.id))
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

    selection_label_strings = build_selection_label_strings(assigns.selection_label_strings)

    assigns =
      assigns
      |> assign(:row_id_fun, row_id_fun)
      |> assign(
        :column_entries,
        Enum.map(zipped_columns, fn {slot, config} -> %{slot: slot, config: config} end)
      )
      |> assign(:column_payload, Jason.encode!(column_config))
      |> assign(:flat_rows, flat_rows)
      |> assign(:row_container_id, "#{assigns.id}-rows")
      |> assign(:has_actions?, assigns.action != [])
      |> assign(:selectable?, assigns.selectable)
      |> assign(:selection_payload, selection_payload)
      |> assign(:selection_hash, selection_hash)
      |> assign(:selection_label_target, assigns.selection_label_target)
      |> assign(:selection_label_strings, selection_label_strings)
      |> assign(:searchable?, assigns.searchable)
      |> assign(:search_fields_fun, assigns.search_fields)
      |> assign(:rest_attrs, clean_rest(assigns.rest))

    ~H"""
    <div
      id={@id}
      class={[
        "rich-table",
        "rounded-xl border border-base-300 bg-base-100",
        @class
      ]}
      phx-hook="RichTable"
      data-columns={@column_payload}
      data-column-resize-event={@column_resize_event}
      data-column-order-event={@column_order_event}
      data-row-drop-event={@row_drop_event}
      data-row-drag-event={@row_drag_event}
      data-selectable={@selectable? && "true"}
      data-selection-event={@selectable? && @selection_event}
      data-selected-rows={@selectable? && @selection_payload}
      data-selection-hash={@selectable? && @selection_hash}
      data-selection-label-target={
        if(@selectable? && @selection_label_target, do: @selection_label_target)
      }
      data-selection-label-none={
        if(@selectable? && @selection_label_target, do: @selection_label_strings.none)
      }
      data-selection-label-single={
        if(@selectable? && @selection_label_target, do: @selection_label_strings.single)
      }
      data-selection-label-multiple={
        if(@selectable? && @selection_label_target, do: @selection_label_strings.multiple)
      }
      data-selection-label-all={
        if(@selectable? && @selection_label_target, do: @selection_label_strings.all)
      }
      data-searchable={@searchable? && "true"}
      style={"--rich-table-indent-size: #{@row_indent}px;"}
      {@rest_attrs}
    >
      <div class="rich-table__scroll">
        <table class="rich-table__table">
          <thead>
            <tr>
              <th
                :if={@selectable?}
                class="rich-table__header-cell rich-table__header-cell--selection"
              >
                <label class="sr-only">{gettext("Toggle all rows")}</label>
                <input
                  type="checkbox"
                  class="rich-table__selection-checkbox"
                  data-selection-control="header"
                  aria-label={gettext("Toggle all rows")}
                />
              </th>
              <th
                :for={entry <- @column_entries}
                data-col-id={entry.config.id}
                data-min-width={entry.config.min_width}
                data-resizable={entry.config.resizable}
                data-reorderable={entry.config.reorderable}
                style={header_style(entry.config)}
                class={[
                  "rich-table__header-cell",
                  entry.slot[:class]
                ]}
                draggable={entry.config.reorderable}
              >
                <span class="rich-table__header-label">{entry.slot[:label]}</span>
              </th>
              <th :if={@has_actions?} class="rich-table__header-cell rich-table__header-cell--actions">
                <span class="sr-only">{gettext("Row actions")}</span>
              </th>
            </tr>
          </thead>
          <tbody id={@row_container_id} data-role="rich-table-body">
            <tr
              :for={row <- @flat_rows}
              id={"#{@id}-row-#{row.id}"}
              data-row-id={row.id}
              data-depth={row.depth}
              data-parent-id={row.parent_id}
              data-draggable={row.draggable}
              data-droppable={row.droppable}
              data-selected={row.selected && "true"}
              data-search-text={build_search_text(@searchable?, @search_fields_fun, row.presented)}
              draggable={row.draggable}
              class={row_classes(row, @row_class)}
              phx-click={maybe_row_click(@row_click, row.presented)}
            >
              <td :if={@selectable?} class="rich-table__cell rich-table__cell--selection">
                <input
                  type="checkbox"
                  class="rich-table__selection-checkbox"
                  data-selection-control="row"
                  data-row-id={row.id}
                  checked={row.selected}
                  aria-label={gettext("Select %{row}", row: row_selection_label(row.presented))}
                />
              </td>
              <td
                :for={{entry, index} <- Enum.with_index(@column_entries)}
                class={[
                  "rich-table__cell",
                  index == 0 && "rich-table__cell--first"
                ]}
                data-col-id={entry.config.id}
              >
                <div
                  class={[
                    "rich-table__cell-inner",
                    index == 0 && "rich-table__cell-inner--with-indent"
                  ]}
                  style={indent_style(row.depth)}
                >
                  <%= if index == 0 do %>
                    <button
                      type="button"
                      class="rich-table__drag-handle"
                      data-row-handle="true"
                      aria-label={gettext("Reorder row")}
                      tabindex="-1"
                    >
                      <span aria-hidden="true"></span>
                    </button>
                    <span
                      :if={row.type == :folder}
                      class="rich-table__folder-indicator"
                      aria-hidden="true"
                    >
                    </span>
                  <% end %>
                  {render_slot(entry.slot, %{
                    row: row.presented,
                    depth: row.depth,
                    column_id: entry.config.id,
                    row_id: row.id
                  })}
                </div>
              </td>
              <td :if={@has_actions?} class="rich-table__cell rich-table__cell--actions">
                <div class="rich-table__row-actions">
                  <%= for action <- @action do %>
                    {render_slot(action, %{row: row.presented, depth: row.depth, row_id: row.id})}
                  <% end %>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp header_style(%{width: nil, min_width: min}), do: "min-width: #{min}px;"

  defp header_style(%{width: width, min_width: min}) do
    "width: #{width}px; min-width: #{min}px;"
  end

  defp indent_style(depth) do
    "--rich-table-depth: #{depth};"
  end

  defp row_classes(row, row_class) do
    [
      "rich-table__row",
      row.type == :folder && "rich-table__row--folder",
      row.draggable == false && "rich-table__row--static",
      row.selected && "rich-table__row--selected",
      row_class(row_class, row.presented)
    ]
  end

  defp row_selection_label(row) do
    row_value(row, :name, "name") ||
      row_value(row, :title, "title") ||
      row_value(row, :id, "id") ||
      gettext("row")
  rescue
    _ -> gettext("row")
  end

  defp row_class(nil, _row), do: nil
  defp row_class(fun, row) when is_function(fun, 1), do: fun.(row)
  defp row_class(value, _row), do: value

  defp maybe_row_click(nil, _row), do: nil
  defp maybe_row_click(%JS{} = js, _row), do: js
  defp maybe_row_click(fun, row) when is_function(fun, 1), do: fun.(row)
  defp maybe_row_click(event, _row), do: event

  defp column_config(slot) do
    %{
      id: slot.id,
      label: slot[:label],
      width: normalize_size(slot[:width]),
      min_width: normalize_size(slot[:min_width]) || 120,
      resizable: slot[:resizable] != false,
      reorderable: slot[:reorderable] != false
    }
  end

  defp normalize_size(value), do: Parse.positive_integer_or_nil(value)

  defp build_row_id_fun(nil) do
    fn row ->
      Map.get(row, :id) || Map.get(row, "id") ||
        raise ArgumentError,
              "rich_table expects rows to include an :id key or a custom :row_id function"
    end
  end

  defp build_row_id_fun(fun) when is_function(fun, 1), do: fun

  defp build_row_id_fun(field) when is_atom(field) do
    fn row ->
      Map.get(row, field) ||
        raise ArgumentError,
              "rich_table could not find #{inspect(field)} on #{inspect(row)}"
    end
  end

  defp build_row_id_fun(field) when is_binary(field) do
    fn row ->
      Map.get(row, field) ||
        fetch_binary_atom_key(row, field) ||
        raise ArgumentError,
              "rich_table could not find #{inspect(field)} on #{inspect(row)}"
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

    current = %{
      id: row_id,
      original: row,
      presented: row_item.(row),
      depth: depth,
      parent_id: parent_id,
      type: normalize_type(row_value(row, :type, "type")),
      draggable: normalize_boolean(row_value(row, :draggable, "draggable"), true),
      droppable: normalize_boolean(row_value(row, :droppable, "droppable"), true)
    }

    children =
      row
      |> row_value(:children, "children")
      |> List.wrap()
      |> Enum.flat_map(&flatten_row(&1, row_id_fun, row_item, depth + 1, row_id))

    [current | children]
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

  defp build_selection_label_strings(strings) do
    defaults = %{
      none: gettext("No rows selected"),
      single: gettext("1 row selected"),
      multiple: gettext("%COUNT% rows selected"),
      all: gettext("All %COUNT% rows selected")
    }

    strings
    |> normalize_label_strings()
    |> Map.merge(defaults, fn _key, _left, right -> right end)
  end

  defp normalize_label_strings(strings) when is_map(strings) do
    Enum.reduce(strings, %{}, fn {key, value}, acc ->
      atom_key =
        cond do
          is_atom(key) -> key
          is_binary(key) -> safe_to_existing_atom(key)
          true -> nil
        end

      if atom_key in [:none, :single, :multiple, :all] and is_binary(value) do
        Map.put(acc, atom_key, value)
      else
        acc
      end
    end)
  end

  defp normalize_label_strings(_), do: %{}

  defp clean_rest(nil), do: %{}
  defp clean_rest(rest) when is_map(rest), do: Map.drop(rest, [:class, "class"])
  defp clean_rest(rest), do: rest |> Enum.into(%{}) |> Map.drop([:class, "class"])

  defp build_search_text(false, _fun, _row), do: nil
  defp build_search_text(true, nil, _row), do: nil

  defp build_search_text(true, fun, row) when is_function(fun, 1) do
    row
    |> fun.()
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 != "" and &1 != "nil"))
    |> Enum.join(" ")
    |> String.downcase()
  end
end
