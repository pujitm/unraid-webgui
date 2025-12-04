defmodule Unraid.EventLog.Context do
  @moduledoc """
  Process-local context for event log entries.

  Context is automatically included in `EventLog.emit/1` calls via the
  `execution_context` field. Set at request boundaries (Plug, LiveView) or manually.

  ## Usage

  Set context at the entry point of your request:

      # In a Plug
      Context.merge(%{
        client: "api",
        user: conn.assigns.current_user,
        request_id: generate_request_id()
      })

      # In a LiveView on_mount
      Context.merge(%{
        client: "liveview",
        user: session["user"],
        request_id: "lv_" <> generate_id()
      })

  Then call business logic normally - events will include the context:

      Docker.start_container(id)
      # Event automatically has execution_context with client, user, request_id

  ## Temporary Context

  Use `with_context/2` to add context for a specific operation:

      Context.with_context(%{reason: "scheduled_task"}, fn ->
        Docker.restart_container(id)
      end)
  """

  @context_key :event_log_context

  @doc """
  Sets a single context field.

  ## Example

      Context.put(:client, "cli")
      Context.put(:user, "admin")
  """
  @spec put(atom(), term()) :: term()
  def put(key, value) do
    current = get_all()
    Process.put(@context_key, Map.put(current, key, value))
  end

  @doc """
  Merges multiple context fields at once.

  ## Example

      Context.merge(%{
        client: "liveview",
        user: "admin",
        request_id: "lv_abc123"
      })
  """
  @spec merge(map()) :: term()
  def merge(map) when is_map(map) do
    current = get_all()
    Process.put(@context_key, Map.merge(current, map))
  end

  @doc """
  Gets a single context field.

  ## Example

      Context.get(:client)
      #=> "liveview"

      Context.get(:missing, "default")
      #=> "default"
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    get_all() |> Map.get(key, default)
  end

  @doc """
  Gets all context as a map.

  Returns an empty map if no context has been set.
  """
  @spec get_all() :: map()
  def get_all do
    Process.get(@context_key, %{})
  end

  @doc """
  Clears all context.

  Rarely needed since the process dies after the request completes.
  """
  @spec clear() :: term()
  def clear do
    Process.delete(@context_key)
  end

  @doc """
  Executes a function with temporary context additions.

  The additional context is merged for the duration of the function call,
  then the original context is restored.

  ## Example

      Context.merge(%{client: "liveview", user: "admin"})

      Context.with_context(%{reason: "manual_restart"}, fn ->
        Docker.restart_container(id)
        # Events here have: client, user, AND reason
      end)

      # After the block, reason is removed, original context restored
  """
  @spec with_context(map(), (-> result)) :: result when result: term()
  def with_context(additions, fun) when is_map(additions) and is_function(fun, 0) do
    original = get_all()
    merge(additions)

    try do
      fun.()
    after
      Process.put(@context_key, original)
    end
  end
end
