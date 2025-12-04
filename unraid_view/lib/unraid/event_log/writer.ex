defmodule Unraid.EventLog.Writer do
  @moduledoc """
  GenServer responsible for file I/O and in-memory caching of events.

  Serializes all writes to prevent file corruption and maintains a bounded
  in-memory cache of recent events for fast queries.
  """

  use GenServer
  require Logger

  alias Unraid.EventLog.Event
  alias Phoenix.PubSub

  @pubsub Unraid.PubSub
  @all_events_topic "events:all"
  @source_topic_prefix "events:source:"
  @task_topic_prefix "events:task:"
  @event_topic_prefix "events:event:"

  # Default configuration
  @default_recent_limit 500

  # State
  defstruct [
    :log_dir,
    :file_handle,
    :current_path,
    :current_month,
    recent_events: :queue.new(),
    events_by_id: %{},
    recent_limit: @default_recent_limit
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Emits a new event to the log.
  """
  @spec emit(map()) :: {:ok, Event.t()} | {:error, term()}
  def emit(attrs) do
    GenServer.call(__MODULE__, {:emit, attrs})
  end

  @doc """
  Updates an existing event.
  """
  @spec update(String.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  def update(event_id, changes) do
    GenServer.call(__MODULE__, {:update, event_id, changes})
  end

  @doc """
  Adds a link to an existing event.
  """
  @spec add_link(String.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  def add_link(event_id, link_attrs) do
    GenServer.call(__MODULE__, {:add_link, event_id, link_attrs})
  end

  @doc """
  Gets recent events from the in-memory cache.

  Options:
  - `:limit` - max events to return (default 50)
  - `:source` - filter by source
  - `:status` - filter by status
  - `:after` - only events after this datetime
  """
  @spec recent(keyword()) :: [Event.t()]
  def recent(opts \\ []) do
    GenServer.call(__MODULE__, {:recent, opts})
  end

  @doc """
  Gets a specific event by ID.
  """
  @spec get(String.t()) :: Event.t() | nil
  def get(event_id) do
    GenServer.call(__MODULE__, {:get, event_id})
  end

  @doc """
  Gets all events in a task tree (parent + children).
  """
  @spec get_task_tree(String.t()) :: [Event.t()]
  def get_task_tree(parent_id) do
    GenServer.call(__MODULE__, {:get_task_tree, parent_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:unraid, Unraid.EventLog, [])

    log_dir =
      opts[:log_dir] ||
        config[:log_dir] ||
        Path.join([File.cwd!(), "tmp", "event_logs"])

    recent_limit = config[:recent_limit] || @default_recent_limit

    state = %__MODULE__{
      log_dir: log_dir,
      recent_limit: recent_limit
    }

    {:ok, state, {:continue, :init_log_file}}
  end

  @impl true
  def handle_continue(:init_log_file, state) do
    # Ensure directory exists
    File.mkdir_p!(state.log_dir)

    # Open current month's file
    {year, month, _day} = Date.utc_today() |> Date.to_erl()
    current_month = {year, month}
    path = log_path(state.log_dir, current_month)

    # Open file in append mode
    {:ok, handle} = File.open(path, [:append, :utf8])

    state = %{state | file_handle: handle, current_path: path, current_month: current_month}

    # Load recent events from file
    state = load_recent_events(state)

    Logger.info("[EventLog.Writer] Started, log_dir=#{state.log_dir}, loaded #{:queue.len(state.recent_events)} events")

    {:noreply, state}
  end

  @impl true
  def handle_call({:emit, attrs}, _from, state) do
    case Event.new(attrs) do
      {:ok, event} ->
        state = write_event(state, event)
        state = cache_event(state, event)
        broadcast_created(event)
        {:reply, {:ok, event}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update, event_id, changes}, _from, state) do
    case Map.get(state.events_by_id, event_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      event ->
        {:ok, updated_event, change_map} = Event.update(event, changes)
        state = write_event(state, updated_event)
        state = update_cached_event(state, updated_event)
        broadcast_updated(updated_event, change_map)
        {:reply, {:ok, updated_event}, state}
    end
  end

  @impl true
  def handle_call({:add_link, event_id, link_attrs}, _from, state) do
    case Map.get(state.events_by_id, event_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      event ->
        {:ok, updated_event, change_map} = Event.add_link(event, link_attrs)
        state = write_event(state, updated_event)
        state = update_cached_event(state, updated_event)
        broadcast_updated(updated_event, change_map)
        {:reply, {:ok, updated_event}, state}
    end
  end

  @impl true
  def handle_call({:recent, opts}, _from, state) do
    limit = opts[:limit] || 50
    source = opts[:source]
    status = opts[:status]
    after_dt = opts[:after]

    events =
      state.recent_events
      |> :queue.to_list()
      |> Enum.reverse()
      |> filter_events(source, status, after_dt)
      |> Enum.take(limit)

    {:reply, events, state}
  end

  @impl true
  def handle_call({:get, event_id}, _from, state) do
    event = Map.get(state.events_by_id, event_id)
    {:reply, event, state}
  end

  @impl true
  def handle_call({:get_task_tree, parent_id}, _from, state) do
    parent = Map.get(state.events_by_id, parent_id)

    children =
      state.events_by_id
      |> Map.values()
      |> Enum.filter(&(&1.parent_id == parent_id))
      |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})

    events = if parent, do: [parent | children], else: children
    {:reply, events, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.file_handle do
      File.close(state.file_handle)
    end

    :ok
  end

  # Private helpers

  defp log_path(dir, {year, month}) do
    filename = "events-#{year}-#{String.pad_leading(to_string(month), 2, "0")}.jsonl"
    Path.join(dir, filename)
  end

  defp write_event(state, event) do
    # Check if we need to rotate to a new month
    {year, month, _day} = Date.utc_today() |> Date.to_erl()
    current_month = {year, month}

    state =
      if current_month != state.current_month do
        rotate_log_file(state, current_month)
      else
        state
      end

    # Write JSON line
    json = Jason.encode!(event) <> "\n"
    IO.write(state.file_handle, json)

    state
  end

  defp rotate_log_file(state, new_month) do
    # Close old file
    if state.file_handle do
      File.close(state.file_handle)
    end

    # Open new file
    path = log_path(state.log_dir, new_month)
    {:ok, handle} = File.open(path, [:append, :utf8])

    Logger.info("[EventLog.Writer] Rotated to new log file: #{path}")

    %{state | file_handle: handle, current_path: path, current_month: new_month}
  end

  defp cache_event(state, event) do
    # Add to queue
    queue = :queue.in(event, state.recent_events)

    # Trim if over limit
    {queue, events_by_id} =
      if :queue.len(queue) > state.recent_limit do
        {{:value, old}, queue} = :queue.out(queue)
        # Remove old event from index
        {queue, Map.delete(state.events_by_id, old.id)}
      else
        {queue, state.events_by_id}
      end

    # Add new event to index
    events_by_id = Map.put(events_by_id, event.id, event)

    %{state | recent_events: queue, events_by_id: events_by_id}
  end

  defp update_cached_event(state, event) do
    # Update in index
    events_by_id = Map.put(state.events_by_id, event.id, event)

    # Update in queue (rebuild with updated event)
    queue =
      state.recent_events
      |> :queue.to_list()
      |> Enum.map(fn e ->
        if e.id == event.id, do: event, else: e
      end)
      |> :queue.from_list()

    %{state | recent_events: queue, events_by_id: events_by_id}
  end

  defp load_recent_events(state) do
    case File.read(state.current_path) do
      {:ok, content} ->
        events =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_line/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, e} -> e end)
          # Take most recent events up to limit
          |> Enum.take(-state.recent_limit)

        # Build initial state
        queue = :queue.from_list(events)
        events_by_id = Map.new(events, &{&1.id, &1})

        %{state | recent_events: queue, events_by_id: events_by_id}

      {:error, :enoent} ->
        # File doesn't exist yet, that's fine
        state

      {:error, reason} ->
        Logger.warning("[EventLog.Writer] Failed to load events: #{inspect(reason)}")
        state
    end
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, json} -> Event.from_json(json)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp filter_events(events, nil, nil, nil), do: events

  defp filter_events(events, source, status, after_dt) do
    events
    |> filter_by_source(source)
    |> filter_by_status(status)
    |> filter_by_time(after_dt)
  end

  defp filter_by_source(events, nil), do: events
  defp filter_by_source(events, source), do: Enum.filter(events, &(&1.source == source))

  defp filter_by_status(events, nil), do: events

  defp filter_by_status(events, status) when is_atom(status) do
    Enum.filter(events, &(&1.status == status))
  end

  defp filter_by_status(events, status) when is_binary(status) do
    filter_by_status(events, String.to_existing_atom(status))
  rescue
    _ -> events
  end

  defp filter_by_time(events, nil), do: events

  defp filter_by_time(events, after_dt) do
    Enum.filter(events, &(DateTime.compare(&1.timestamp, after_dt) == :gt))
  end

  # PubSub broadcasting

  defp broadcast_created(event) do
    message = {:event_created, event}

    # Broadcast to all subscribers
    PubSub.broadcast(@pubsub, @all_events_topic, message)

    # Broadcast to source-specific topic
    PubSub.broadcast(@pubsub, "#{@source_topic_prefix}#{event.source}", message)

    # Broadcast to task topic if part of a task tree
    if event.parent_id do
      PubSub.broadcast(@pubsub, "#{@task_topic_prefix}#{event.parent_id}", message)
    end

    # Broadcast to event-specific topic
    PubSub.broadcast(@pubsub, "#{@event_topic_prefix}#{event.id}", message)
  end

  defp broadcast_updated(event, changes) do
    message = {:event_updated, event, changes}

    # Broadcast to all subscribers
    PubSub.broadcast(@pubsub, @all_events_topic, message)

    # Broadcast to source-specific topic
    PubSub.broadcast(@pubsub, "#{@source_topic_prefix}#{event.source}", message)

    # Broadcast to task topic if part of a task tree
    if event.parent_id do
      PubSub.broadcast(@pubsub, "#{@task_topic_prefix}#{event.parent_id}", message)
    end

    # Broadcast to event-specific topic
    PubSub.broadcast(@pubsub, "#{@event_topic_prefix}#{event.id}", message)
  end
end
