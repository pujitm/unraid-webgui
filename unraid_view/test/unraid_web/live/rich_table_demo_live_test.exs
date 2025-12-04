defmodule UnraidWeb.RichTableDemoLiveTest do
  use UnraidWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The RichTableDemoLive has a 200ms interval timer that causes :sys.get_state()
  # to be very slow. We use a longer timeout and avoid repeated render() calls.

  test "renders the demo table and reacts to interactions", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, UnraidWeb.RichTableDemoLive)

    assert html =~ "Rich Table Demo"
    assert has_element?(view, "#rich-table-demo")

    result =
      view
      |> element("button[phx-value-id='production']")
      |> render_click()

    assert result =~ "Pin toggled"
  end

  test "reorders rows when drop events fire", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, UnraidWeb.RichTableDemoLive)

    render_hook(view, "demo:row_dropped", %{
      "source_id" => "analytics",
      "target_id" => "production",
      "action" => "before"
    })

    row_ids = top_level_ids(view)
    assert Enum.take(row_ids, 2) == ["analytics", "production"]

    render_hook(view, "demo:row_dropped", %{
      "source_id" => "analytics",
      "target_id" => "orders-api",
      "action" => "into"
    })

    assert find_parent_id(live_assign(view, :demo_rows), "analytics") == "orders-api"
  end

  test "selection label reflects selection_changed events", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, UnraidWeb.RichTableDemoLive)

    assert html =~ "No rows selected"

    html = render_hook(view, "demo:selection_changed", %{"selected_ids" => ["production"]})
    assert html =~ "1 row selected"

    html =
      render_hook(view, "demo:selection_changed", %{
        "selected_ids" => ["production", "analytics"]
      })

    assert html =~ "2 rows selected"

    html = render_hook(view, "demo:selection_changed", %{"selected_ids" => []})
    assert html =~ "No rows selected"
  end

  defp top_level_ids(view) do
    live_assign(view, :demo_rows)
    |> Enum.map(& &1.id)
  end

  defp find_parent_id(rows, target_id, parent_id \\ nil)

  defp find_parent_id([], _target_id, _parent_id), do: nil

  defp find_parent_id([row | rest], target_id, parent_id) do
    cond do
      row.id == target_id ->
        parent_id

      true ->
        case find_parent_id(row.children || [], target_id, row.id) do
          nil -> find_parent_id(rest, target_id, parent_id)
          value -> value
        end
    end
  end

  defp live_assign(view, key) do
    # Use :sys.get_state with a timeout since the LiveView has a fast timer
    state = :sys.get_state(view.pid, 5_000)

    state
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(key)
  end
end
