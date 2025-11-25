defmodule UnraidView.TreeTest do
  use ExUnit.Case, async: true

  alias UnraidView.Tree

  # Sample tree structures for testing
  defp flat_tree do
    [
      %{id: "a", name: "Node A"},
      %{id: "b", name: "Node B"},
      %{id: "c", name: "Node C"}
    ]
  end

  defp nested_tree do
    [
      %{
        id: "folder1",
        type: :folder,
        children: [
          %{id: "item1", name: "Item 1"},
          %{id: "item2", name: "Item 2"}
        ]
      },
      %{id: "item3", name: "Item 3"},
      %{
        id: "folder2",
        type: :folder,
        children: [
          %{
            id: "subfolder",
            type: :folder,
            children: [
              %{id: "deep_item", name: "Deep Item"}
            ]
          }
        ]
      }
    ]
  end

  describe "take/2" do
    test "removes a node from a flat list" do
      {updated, node} = Tree.take(flat_tree(), "b")

      assert node.id == "b"
      assert length(updated) == 2
      refute Enum.any?(updated, &(&1.id == "b"))
    end

    test "removes a node from nested children" do
      {updated, node} = Tree.take(nested_tree(), "item1")

      assert node.id == "item1"
      folder = Enum.find(updated, &(&1.id == "folder1"))
      assert length(folder.children) == 1
      assert hd(folder.children).id == "item2"
    end

    test "removes a deeply nested node" do
      {updated, node} = Tree.take(nested_tree(), "deep_item")

      assert node.id == "deep_item"
      folder2 = Enum.find(updated, &(&1.id == "folder2"))
      subfolder = hd(folder2.children)
      assert subfolder.children == []
    end

    test "returns nil for non-existent node" do
      {updated, node} = Tree.take(flat_tree(), "nonexistent")

      assert is_nil(node)
      assert updated == flat_tree()
    end

    test "ensures children key exists on taken node" do
      {_updated, node} = Tree.take(flat_tree(), "a")

      assert Map.has_key?(node, :children)
      assert node.children == []
    end
  end

  describe "take_many/2" do
    test "removes multiple nodes" do
      {updated, nodes} = Tree.take_many(flat_tree(), ["a", "c"])

      assert length(nodes) == 2
      assert Enum.map(nodes, & &1.id) == ["a", "c"]
      assert length(updated) == 1
      assert hd(updated).id == "b"
    end

    test "returns error if any node not found" do
      result = Tree.take_many(flat_tree(), ["a", "nonexistent"])

      assert result == {:error, "Node not found"}
    end

    test "removes nodes from different nesting levels" do
      {updated, nodes} = Tree.take_many(nested_tree(), ["item1", "item3"])

      assert length(nodes) == 2
      folder1 = Enum.find(updated, &(&1.id == "folder1"))
      assert length(folder1.children) == 1
      refute Enum.any?(updated, &(&1.id == "item3"))
    end
  end

  describe "insert_relative/4" do
    test "inserts before a target" do
      {:ok, updated} = Tree.insert_relative(flat_tree(), "b", %{id: "new"}, :before)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["a", "new", "b", "c"]
    end

    test "inserts after a target" do
      {:ok, updated} = Tree.insert_relative(flat_tree(), "b", %{id: "new"}, :after)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["a", "b", "new", "c"]
    end

    test "inserts into nested children" do
      {:ok, updated} = Tree.insert_relative(nested_tree(), "item1", %{id: "new"}, :after)

      folder = Enum.find(updated, &(&1.id == "folder1"))
      child_ids = Enum.map(folder.children, & &1.id)
      assert child_ids == ["item1", "new", "item2"]
    end

    test "returns error for nil target" do
      result = Tree.insert_relative(flat_tree(), nil, %{id: "new"}, :before)

      assert result == {:error, "Target not found"}
    end

    test "returns error for non-existent target" do
      result = Tree.insert_relative(flat_tree(), "nonexistent", %{id: "new"}, :before)

      assert result == {:error, "Target not found"}
    end
  end

  describe "insert_into/3" do
    test "nests a node inside another" do
      {:ok, updated} = Tree.insert_into(flat_tree(), "a", %{id: "child"})

      parent = hd(updated)
      assert parent.type == :folder
      assert length(parent.children) == 1
      assert hd(parent.children).id == "child"
    end

    test "appends to existing children" do
      {:ok, updated} = Tree.insert_into(nested_tree(), "folder1", %{id: "new_child"})

      folder = Enum.find(updated, &(&1.id == "folder1"))
      assert length(folder.children) == 3
      assert List.last(folder.children).id == "new_child"
    end

    test "inserts into deeply nested folder" do
      {:ok, updated} = Tree.insert_into(nested_tree(), "subfolder", %{id: "new_deep"})

      folder2 = Enum.find(updated, &(&1.id == "folder2"))
      subfolder = hd(folder2.children)
      assert length(subfolder.children) == 2
    end

    test "returns error for nil target" do
      result = Tree.insert_into(flat_tree(), nil, %{id: "child"})

      assert result == {:error, "Target not found"}
    end

    test "returns error for non-existent target" do
      result = Tree.insert_into(flat_tree(), "nonexistent", %{id: "child"})

      assert result == {:error, "Target not found"}
    end
  end

  describe "append/2" do
    test "appends to the root level" do
      {:ok, updated} = Tree.append(flat_tree(), %{id: "new"})

      assert length(updated) == 4
      assert List.last(updated).id == "new"
    end
  end

  describe "collect_ids/1" do
    test "collects IDs from a flat list" do
      ids = Tree.collect_ids(flat_tree())

      assert ids == ["a", "b", "c"]
    end

    test "collects IDs from nested tree" do
      ids = Tree.collect_ids(nested_tree())

      assert "folder1" in ids
      assert "item1" in ids
      assert "item2" in ids
      assert "item3" in ids
      assert "folder2" in ids
      assert "subfolder" in ids
      assert "deep_item" in ids
    end

    test "handles empty list" do
      assert Tree.collect_ids([]) == []
    end

    test "handles single node" do
      ids = Tree.collect_ids(%{id: "single", children: [%{id: "child"}]})

      assert ids == ["single", "child"]
    end
  end

  describe "descendant?/2" do
    test "returns true for direct child" do
      node = %{id: "parent", children: [%{id: "child"}]}

      assert Tree.descendant?(node, "child")
    end

    test "returns true for deeply nested descendant" do
      node = %{
        id: "a",
        children: [
          %{id: "b", children: [%{id: "c", children: [%{id: "d"}]}]}
        ]
      }

      assert Tree.descendant?(node, "d")
    end

    test "returns false for non-descendant" do
      node = %{id: "parent", children: [%{id: "child"}]}

      refute Tree.descendant?(node, "other")
    end

    test "returns false for nil node" do
      refute Tree.descendant?(nil, "any")
    end

    test "returns false for node without children" do
      node = %{id: "leaf"}

      refute Tree.descendant?(node, "any")
    end
  end

  describe "apply_drop/2 - single row" do
    test "moves row to end of list" do
      {:ok, updated} = Tree.apply_drop(flat_tree(), %{"source_id" => "a", "action" => "end"})

      ids = Enum.map(updated, & &1.id)
      assert ids == ["b", "c", "a"]
    end

    test "moves row before target" do
      params = %{"source_id" => "c", "target_id" => "a", "action" => "before"}
      {:ok, updated} = Tree.apply_drop(flat_tree(), params)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["c", "a", "b"]
    end

    test "moves row after target" do
      params = %{"source_id" => "a", "target_id" => "c", "action" => "after"}
      {:ok, updated} = Tree.apply_drop(flat_tree(), params)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["b", "c", "a"]
    end

    test "nests row into target" do
      params = %{"source_id" => "b", "target_id" => "a", "action" => "into"}
      {:ok, updated} = Tree.apply_drop(flat_tree(), params)

      parent = hd(updated)
      assert parent.id == "a"
      assert parent.type == :folder
      assert hd(parent.children).id == "b"
    end

    test "rejects dropping onto itself" do
      params = %{"source_id" => "a", "target_id" => "a", "action" => "into"}
      result = Tree.apply_drop(flat_tree(), params)

      assert result == {:error, "Cannot drop onto itself"}
    end

    test "rejects dropping into a descendant" do
      tree = [%{id: "parent", children: [%{id: "child"}]}]
      params = %{"source_id" => "parent", "target_id" => "child", "action" => "into"}
      result = Tree.apply_drop(tree, params)

      assert result == {:error, "Cannot move into a descendant"}
    end

    test "returns error for non-existent source" do
      params = %{"source_id" => "nonexistent", "target_id" => "a", "action" => "before"}
      result = Tree.apply_drop(flat_tree(), params)

      assert result == {:error, "Node not found"}
    end

    test "handles missing params gracefully" do
      {:ok, updated} = Tree.apply_drop(flat_tree(), %{})

      assert updated == flat_tree()
    end
  end

  describe "apply_drop/2 - multi row" do
    test "moves multiple rows to end" do
      params = %{"source_ids" => ["a", "b"], "action" => "end"}
      {:ok, updated} = Tree.apply_drop(flat_tree(), params)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["c", "a", "b"]
    end

    test "moves multiple rows before target" do
      params = %{"source_ids" => ["a", "b"], "target_id" => "c", "action" => "before"}
      {:ok, updated} = Tree.apply_drop(flat_tree(), params)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["b", "a", "c"]
    end

    test "moves multiple rows after target" do
      tree = [%{id: "x"}, %{id: "a"}, %{id: "b"}, %{id: "c"}]
      params = %{"source_ids" => ["a", "b"], "target_id" => "x", "action" => "after"}
      {:ok, updated} = Tree.apply_drop(tree, params)

      ids = Enum.map(updated, & &1.id)
      assert ids == ["x", "a", "b", "c"]
    end

    test "nests multiple rows into target" do
      params = %{"source_ids" => ["b", "c"], "target_id" => "a", "action" => "into"}
      {:ok, updated} = Tree.apply_drop(flat_tree(), params)

      parent = hd(updated)
      assert parent.type == :folder
      child_ids = Enum.map(parent.children, & &1.id)
      assert child_ids == ["b", "c"]
    end

    test "rejects when any source is the target" do
      params = %{"source_ids" => ["a", "b"], "target_id" => "a", "action" => "before"}
      result = Tree.apply_drop(flat_tree(), params)

      assert result == {:error, "Cannot drop onto itself"}
    end

    test "returns error when any source not found" do
      params = %{"source_ids" => ["a", "nonexistent"], "action" => "end"}
      result = Tree.apply_drop(flat_tree(), params)

      assert result == {:error, "Node not found"}
    end
  end

  describe "string keys support" do
    test "works with string keys" do
      tree = [%{"id" => "a"}, %{"id" => "b", "children" => [%{"id" => "c"}]}]

      ids = Tree.collect_ids(tree)
      assert ids == ["a", "b", "c"]

      {_updated, node} = Tree.take(tree, "c")
      assert node["id"] == "c"
    end
  end
end
