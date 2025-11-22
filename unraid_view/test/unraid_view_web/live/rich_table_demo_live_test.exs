defmodule UnraidViewWeb.RichTableDemoLiveTest do
  use UnraidViewWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the demo table and reacts to interactions", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, UnraidViewWeb.RichTableDemoLive)

    assert html =~ "Rich Table Demo"
    assert has_element?(view, "#rich-table-demo")

    view
    |> element("button[phx-value-id='production']")
    |> render_click()

    assert render(view) =~ "Pin toggled"
  end

  test "reorders rows when drop events fire", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, UnraidViewWeb.RichTableDemoLive)

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
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(key)
  end
end
