defmodule UnraidView.Tree do
  @moduledoc """
  Generic tree manipulation utilities for drag & drop operations.

  Provides pure functions to transform nested tree structures commonly used
  in LiveView tables and lists. All functions operate on lists of maps/structs
  where each node has an `:id` key and optionally a `:children` key.

  ## Usage in LiveViews

      alias UnraidView.Tree

      def handle_event("row_dropped", params, socket) do
        case Tree.apply_drop(socket.assigns.items, params) do
          {:ok, updated} ->
            valid_ids = Tree.collect_ids(updated)
            {:noreply, assign(socket, items: updated)}

          {:error, _reason} ->
            {:noreply, socket}
        end
      end

  ## Node Structure

  Nodes are maps with at minimum an `:id` key. Optional keys:

    * `:children` - list of child nodes (for folders/groups)
    * `:type` - set to `:folder` automatically when nesting

  Both atom and string keys are supported for `:id` and `:children`.
  """

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Apply a drop operation from rich_table event params.

  Handles both single and multi-row drops. Validates the operation
  and returns either the updated tree or an error.

  ## Parameters

    * `tree` - List of root nodes
    * `params` - Map from LiveView event with keys:
      * `"source_id"` or `"source_ids"` - ID(s) being moved
      * `"target_id"` - Drop target ID (nil for end of list)
      * `"action"` - "before" | "after" | "into" | "end"

  ## Examples

      iex> tree = [%{id: "a"}, %{id: "b"}]
      iex> Tree.apply_drop(tree, %{"source_id" => "a", "target_id" => "b", "action" => "after"})
      {:ok, [%{id: "b"}, %{id: "a", children: []}]}

      iex> Tree.apply_drop(tree, %{"source_id" => "a", "target_id" => "a", "action" => "into"})
      {:error, "Cannot drop onto itself"}
  """
  @spec apply_drop(list(map()), map()) :: {:ok, list(map())} | {:error, String.t()}
  def apply_drop(tree, %{"source_ids" => source_ids} = params)
      when is_list(source_ids) and source_ids != [] do
    ids = Enum.uniq(source_ids)

    case take_many(tree, ids) do
      {:error, _} = error ->
        error

      {trimmed, nodes} ->
        target_id = Map.get(params, "target_id")

        with :ok <- validate_multi_drop(nodes, target_id),
             {:ok, updated} <- insert_multiple(trimmed, nodes, params) do
          {:ok, updated}
        end
    end
  end

  def apply_drop(tree, %{"source_id" => source_id} = params) do
    action = Map.get(params, "action", "end")
    target_id = Map.get(params, "target_id")
    folder_name = Map.get(params, "folder_name")

    {trimmed, source_node} = take(tree, source_id)

    with :ok <- validate_drop(source_node, source_id, target_id) do
      node = ensure_children(source_node)

      case action do
        "before" -> insert_relative(trimmed, target_id, node, :before)
        "after" -> insert_relative(trimmed, target_id, node, :after)
        "into" -> insert_into(trimmed, target_id, node, folder_name)
        "end" -> append(trimmed, node)
        _ -> append(trimmed, node)
      end
    end
  end

  def apply_drop(tree, _params), do: {:ok, tree}

  @doc """
  Remove a node from the tree by ID.

  Returns a tuple of `{updated_tree, removed_node}`. If the node is not found,
  returns `{original_tree, nil}`.

  ## Examples

      iex> tree = [%{id: "a"}, %{id: "b", children: [%{id: "c"}]}]
      iex> {updated, node} = Tree.take(tree, "c")
      iex> node.id
      "c"
      iex> length(updated)
      2
  """
  @spec take(list(map()), String.t()) :: {list(map()), map() | nil}
  def take(tree, node_id) do
    do_take(tree, node_id, [])
  end

  @doc """
  Remove multiple nodes from the tree.

  Returns `{updated_tree, removed_nodes}` or `{:error, reason}` if any node
  is not found.

  ## Examples

      iex> tree = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      iex> {updated, nodes} = Tree.take_many(tree, ["a", "c"])
      iex> length(nodes)
      2
      iex> length(updated)
      1
  """
  @spec take_many(list(map()), list(String.t())) ::
          {list(map()), list(map())} | {:error, String.t()}
  def take_many(tree, ids) do
    ids
    |> Enum.reduce_while({tree, []}, fn id, {acc_tree, acc_nodes} ->
      {next_tree, node} = take(acc_tree, id)

      if is_nil(node) do
        {:halt, {:error, "Node not found"}}
      else
        {:cont, {next_tree, [node | acc_nodes]}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {remaining, nodes} -> {remaining, Enum.reverse(nodes)}
    end
  end

  @doc """
  Insert a node before or after a target node.

  ## Examples

      iex> tree = [%{id: "a"}, %{id: "b"}]
      iex> Tree.insert_relative(tree, "b", %{id: "c"}, :before)
      {:ok, [%{id: "a"}, %{id: "c"}, %{id: "b"}]}
  """
  @spec insert_relative(list(map()), String.t() | nil, map(), :before | :after) ::
          {:ok, list(map())} | {:error, String.t()}
  def insert_relative(_tree, nil, _node, _pos), do: {:error, "Target not found"}

  def insert_relative(tree, target_id, node, pos) do
    case do_insert_relative(tree, target_id, node, pos) do
      {:ok, updated} -> {:ok, updated}
      :not_found -> {:error, "Target not found"}
    end
  end

  @doc """
  Insert a node as a child of a target node (nesting).

  If `folder_name` is provided and target is not already a folder, creates a new
  folder with that name containing both the target and the source node.

  Otherwise, automatically sets the target's `:type` to `:folder`.

  ## Examples

      iex> tree = [%{id: "a"}, %{id: "b"}]
      iex> {:ok, updated} = Tree.insert_into(tree, "a", %{id: "c"})
      iex> hd(updated).type
      :folder
      iex> hd(updated).children
      [%{id: "c"}]

      # With folder_name - creates new folder containing both items
      iex> tree = [%{id: "a"}, %{id: "b"}]
      iex> {:ok, updated} = Tree.insert_into(tree, "a", %{id: "c"}, "My Folder")
      iex> hd(updated).name
      "My Folder"
      iex> length(hd(updated).children)
      2
  """
  @spec insert_into(list(map()), String.t() | nil, map(), String.t() | nil) ::
          {:ok, list(map())} | {:error, String.t()}
  def insert_into(tree, target_id, node, folder_name \\ nil)

  def insert_into(_tree, nil, _node, _folder_name), do: {:error, "Target not found"}

  def insert_into(tree, target_id, node, folder_name) do
    case do_insert_into(tree, target_id, node, folder_name) do
      {:ok, updated} -> {:ok, updated}
      :not_found -> {:error, "Target not found"}
    end
  end

  @doc """
  Append a node to the root level of the tree.

  ## Examples

      iex> Tree.append([%{id: "a"}], %{id: "b"})
      {:ok, [%{id: "a"}, %{id: "b"}]}
  """
  @spec append(list(map()), map()) :: {:ok, list(map())}
  def append(tree, node), do: {:ok, tree ++ [node]}

  @doc """
  Collect all node IDs in the tree, including nested children.

  ## Examples

      iex> tree = [%{id: "a", children: [%{id: "b"}]}, %{id: "c"}]
      iex> Tree.collect_ids(tree)
      ["a", "b", "c"]
  """
  @spec collect_ids(list(map()) | map() | nil) :: list(String.t())
  def collect_ids(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_ids/1)
  end

  def collect_ids(%{id: id} = node) do
    [id | collect_ids(get_children(node))]
  end

  def collect_ids(%{"id" => id} = node) do
    [id | collect_ids(get_children(node))]
  end

  def collect_ids(_), do: []

  @doc """
  Check if `target_id` is a descendant of `node`.

  ## Examples

      iex> node = %{id: "a", children: [%{id: "b", children: [%{id: "c"}]}]}
      iex> Tree.descendant?(node, "c")
      true
      iex> Tree.descendant?(node, "x")
      false
  """
  @spec descendant?(map() | nil, String.t()) :: boolean()
  def descendant?(nil, _target_id), do: false

  def descendant?(node, target_id) do
    children = get_children(node)

    Enum.any?(children, fn child ->
      get_id(child) == target_id || descendant?(child, target_id)
    end)
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp validate_drop(source_node, source_id, target_id) do
    cond do
      is_nil(source_node) ->
        {:error, "Node not found"}

      target_id && source_id == target_id ->
        {:error, "Cannot drop onto itself"}

      target_id && descendant?(source_node, target_id) ->
        {:error, "Cannot move into a descendant"}

      true ->
        :ok
    end
  end

  defp validate_multi_drop(_nodes, nil), do: :ok

  defp validate_multi_drop(nodes, target_id) do
    cond do
      Enum.any?(nodes, &(get_id(&1) == target_id)) ->
        {:error, "Cannot drop onto itself"}

      Enum.any?(nodes, &descendant?(&1, target_id)) ->
        {:error, "Cannot move into a descendant"}

      true ->
        :ok
    end
  end

  defp ensure_children(nil), do: nil

  defp ensure_children(node) do
    Map.update(node, :children, [], fn
      nil -> []
      children -> children
    end)
  end

  # Take a single node from the tree
  defp do_take([], _target_id, acc), do: {Enum.reverse(acc), nil}

  defp do_take([node | rest], target_id, acc) do
    if get_id(node) == target_id do
      {Enum.reverse(acc) ++ rest, ensure_children(node)}
    else
      children = get_children(node)
      {new_children, found} = do_take(children, target_id, [])

      if found do
        updated = set_children(node, new_children)
        {Enum.reverse(acc) ++ [updated | rest], found}
      else
        do_take(rest, target_id, [node | acc])
      end
    end
  end

  # Insert relative to a target (before or after)
  defp do_insert_relative([], _target_id, _node, _pos), do: :not_found

  defp do_insert_relative([current | rest], target_id, node, pos) do
    if get_id(current) == target_id do
      inserted =
        case pos do
          :before -> [node, current | rest]
          :after -> [current, node | rest]
        end

      {:ok, inserted}
    else
      children = get_children(current)

      case do_insert_relative(children, target_id, node, pos) do
        {:ok, new_children} ->
          updated = set_children(current, new_children)
          {:ok, [updated | rest]}

        :not_found ->
          case do_insert_relative(rest, target_id, node, pos) do
            {:ok, updated_rest} -> {:ok, [current | updated_rest]}
            :not_found -> :not_found
          end
      end
    end
  end

  # Insert as a child of the target (nesting)
  # If folder_name is provided and target is not a folder, create a new folder
  # containing both target and source
  defp do_insert_into([], _target_id, _node, _folder_name), do: :not_found

  defp do_insert_into([current | rest], target_id, node, folder_name) do
    if get_id(current) == target_id do
      current_type = Map.get(current, :type) || Map.get(current, "type")
      is_folder = current_type == :folder || current_type == "folder"

      updated =
        cond do
          # Target is already a folder - add source as child
          is_folder ->
            children = get_children(current)

            current
            |> set_children(children ++ [node])

          # folder_name provided - create new folder containing both items
          folder_name && folder_name != "" ->
            %{
              id: generate_folder_id(),
              name: folder_name,
              type: :folder,
              children: [current, node]
            }

          # No folder_name - convert target to folder (legacy behavior)
          true ->
            children = get_children(current)

            current
            |> Map.put(:type, :folder)
            |> set_children(children ++ [node])
        end

      {:ok, [updated | rest]}
    else
      children = get_children(current)

      case do_insert_into(children, target_id, node, folder_name) do
        {:ok, new_children} ->
          updated = set_children(current, new_children)
          {:ok, [updated | rest]}

        :not_found ->
          case do_insert_into(rest, target_id, node, folder_name) do
            {:ok, updated_rest} -> {:ok, [current | updated_rest]}
            :not_found -> :not_found
          end
      end
    end
  end

  defp generate_folder_id do
    "folder-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # Insert multiple nodes based on action
  defp insert_multiple(tree, nodes, params) do
    target_id = Map.get(params, "target_id")
    folder_name = Map.get(params, "folder_name")

    case Map.get(params, "action", "end") do
      "before" ->
        insert_many_before(tree, Enum.reverse(nodes), target_id)

      "after" ->
        insert_many_after(tree, nodes, target_id)

      "into" ->
        insert_many_into(tree, nodes, target_id, folder_name)

      _ ->
        {:ok, tree ++ nodes}
    end
  end

  defp insert_many_before(_tree, _nodes, nil), do: {:error, "Target not found"}
  defp insert_many_before(tree, [], _target_id), do: {:ok, tree}

  defp insert_many_before(tree, [node | rest], target_id) do
    case insert_relative(tree, target_id, node, :before) do
      {:ok, updated} -> insert_many_before(updated, rest, target_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_many_after(_tree, _nodes, nil), do: {:error, "Target not found"}

  defp insert_many_after(tree, nodes, target_id) do
    do_insert_many_after(tree, nodes, target_id)
  end

  defp do_insert_many_after(tree, [], _anchor_id), do: {:ok, tree}

  defp do_insert_many_after(tree, [node | rest], anchor_id) do
    case insert_relative(tree, anchor_id, node, :after) do
      {:ok, updated} -> do_insert_many_after(updated, rest, get_id(node))
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_many_into(_tree, _nodes, nil, _folder_name), do: {:error, "Target not found"}
  defp insert_many_into(tree, [], _target_id, _folder_name), do: {:ok, tree}

  defp insert_many_into(tree, [node | rest], target_id, folder_name) do
    # Only use folder_name for the first insert (creates the folder)
    # Subsequent inserts go into the already-created folder
    case insert_into(tree, target_id, node, folder_name) do
      {:ok, updated} ->
        # After first insert with folder_name, the folder exists
        # Find the new folder's ID to add remaining items to it
        new_target_id =
          if folder_name && folder_name != "" do
            find_folder_containing(updated, target_id)
          else
            target_id
          end

        insert_many_into(updated, rest, new_target_id, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Find the folder that contains a given item ID
  defp find_folder_containing(tree, item_id) do
    Enum.find_value(tree, fn node ->
      children = get_children(node)

      if Enum.any?(children, &(get_id(&1) == item_id)) do
        get_id(node)
      else
        find_folder_containing(children, item_id)
      end
    end)
  end

  # Flexible field accessors for both atom and string keys
  defp get_id(%{id: id}), do: id
  defp get_id(%{"id" => id}), do: id
  defp get_id(_), do: nil

  defp get_children(%{children: children}) when is_list(children), do: children
  defp get_children(%{"children" => children}) when is_list(children), do: children
  defp get_children(_), do: []

  defp set_children(node, children) do
    cond do
      Map.has_key?(node, :children) -> Map.put(node, :children, children)
      Map.has_key?(node, "children") -> Map.put(node, "children", children)
      true -> Map.put(node, :children, children)
    end
  end
end
