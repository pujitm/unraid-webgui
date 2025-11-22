defmodule UnraidViewWeb.RichTableComponentsTest do
  use UnraidViewWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import UnraidViewWeb.RichTableComponents
  alias Floki

  describe "rich_table/1" do
    test "renders nested rows with depth data attributes" do
      rows = [
        %{id: "alpha", name: "Alpha", type: :folder, children: [%{id: "beta", name: "Beta"}]},
        %{id: "gamma", name: "Gamma"}
      ]

      assigns = %{rows: rows}

      html =
        rendered_to_string(~H"""
        <.rich_table id="demo-table" rows={@rows}>
          <:col :let={slot} id="name" label="Name">
            {slot.row.name}
          </:col>
        </.rich_table>
        """)

      assert html =~ ~s(id="demo-table")
      assert html =~ ~s(data-row-id="alpha")
      assert html =~ ~s(data-row-id="beta")
      assert html =~ ~s(data-row-id="gamma")
      assert html =~ ~s(data-depth="1")

      columns_attr =
        html
        |> Floki.parse_fragment!()
        |> Floki.attribute("div[phx-hook=RichTable]", "data-columns")
        |> List.first()

      assert columns_attr =~ ~s("id":"name")
    end

    test "accepts custom row_id functions" do
      rows = [
        %{slug: "first", name: "First"},
        %{slug: "second", name: "Second"}
      ]

      assigns = %{rows: rows}

      html =
        rendered_to_string(~H"""
        <.rich_table id="custom-id" rows={@rows} row_id={:slug}>
          <:col :let={slot} id="name" label="Name">
            {slot.row.name}
          </:col>
        </.rich_table>
        """)

      assert html =~ ~s(data-row-id="first")
      assert html =~ ~s(data-row-id="second")
    end
  end
end
