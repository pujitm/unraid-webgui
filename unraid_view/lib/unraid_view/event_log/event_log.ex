defmodule UnraidView.EventLog do
  @moduledoc """
  Context module for the append-only event log system.

  Provides a clean API for emitting events, querying history, and subscribing
  to real-time updates. Events are persisted to disk and broadcast via PubSub.

  ## PubSub Topics

    * `"events:all"` - All new and updated events
    * `"events:source:<source>"` - Events from a specific source (e.g., "events:source:docker")
    * `"events:task:<parent_id>"` - Updates for a specific task tree
    * `"events:event:<event_id>"` - Updates for a specific event

  ## Message Formats

    * `{:event_created, %Event{}}` - New event was created
    * `{:event_updated, %Event{}, changes}` - Event was updated, changes is a map of what changed

  ## Examples

      # Emit a simple event
      {:ok, event} = EventLog.emit(%{
        source: "docker",
        category: "container.start",
        summary: "Started nginx container"
      })

      # Emit a running task
      {:ok, task} = EventLog.emit(%{
        source: "system",
        category: "parity.check",
        summary: "Parity check started",
        status: :running,
        progress: 0
      })

      # Update task progress
      {:ok, updated} = EventLog.update(task.id, %{progress: 50})

      # Add a link to the task
      {:ok, with_link} = EventLog.add_link(task.id, %{
        type: :log_file,
        label: "Parity log",
        target: "/var/log/parity.log",
        tailable: true
      })

      # Complete the task
      {:ok, completed} = EventLog.update(task.id, %{status: :completed, progress: 100})

      # Subscribe to all events
      EventLog.subscribe()

      # Subscribe to a specific event for real-time updates
      EventLog.subscribe_event(task.id)
  """

  alias UnraidView.EventLog.{Event, Writer}
  alias Phoenix.PubSub

  @pubsub UnraidView.PubSub
  @all_events_topic "events:all"
  @source_topic_prefix "events:source:"
  @task_topic_prefix "events:task:"
  @event_topic_prefix "events:event:"

  @doc """
  Emits a new event to the log.

  Required fields:
  - `:source` - Origin module/subsystem (e.g., "docker", "system")
  - `:category` - Event category (e.g., "container.start")
  - `:summary` - Human-readable one-line summary

  Optional fields:
  - `:severity` - `:debug | :info | :notice | :warning | :error` (default: `:info`)
  - `:status` - `:pending | :running | :completed | :failed | :cancelled` (default: `:completed`)
  - `:parent_id` - ID of parent event for hierarchical tasks
  - `:progress` - 0-100 percentage for running tasks
  - `:links` - list of link maps
  - `:metadata` - arbitrary map of additional data

  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec emit(map()) :: {:ok, Event.t()} | {:error, term()}
  defdelegate emit(attrs), to: Writer

  @doc """
  Updates an existing event.

  Supported fields:
  - `:status` - New status
  - `:progress` - New progress percentage
  - `:summary` - Updated summary
  - `:metadata` - Map to merge into existing metadata

  Automatically sets `completed_at` when status changes to a terminal state.

  Returns `{:ok, updated_event}` or `{:error, :not_found}`.
  """
  @spec update(String.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  defdelegate update(event_id, changes), to: Writer

  @doc """
  Adds a link to an existing event.

  Link attributes:
  - `:type` - `:log_file | :url | :terminal | :container` (default: `:url`)
  - `:label` - Display label for the link
  - `:target` - File path, URL, or ID
  - `:tailable` - Whether the resource can be streamed/followed (default: `false`)

  Returns `{:ok, updated_event}` or `{:error, :not_found}`.
  """
  @spec add_link(String.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  defdelegate add_link(event_id, link_attrs), to: Writer

  @doc """
  Gets recent events from the in-memory cache.

  Options:
  - `:limit` - Max events to return (default: 50)
  - `:source` - Filter by source (e.g., "docker")
  - `:status` - Filter by status (e.g., `:running`)
  - `:after` - Only events after this datetime

  Returns a list of events, most recent first.
  """
  @spec recent(keyword()) :: [Event.t()]
  defdelegate recent(opts \\ []), to: Writer

  @doc """
  Gets a specific event by ID.

  Returns the event or `nil` if not found.
  """
  @spec get(String.t()) :: Event.t() | nil
  defdelegate get(event_id), to: Writer

  @doc """
  Gets all events in a task tree (parent + children).

  Returns a list with the parent first, followed by children sorted by timestamp.
  """
  @spec get_task_tree(String.t()) :: [Event.t()]
  defdelegate get_task_tree(parent_id), to: Writer

  @doc """
  Subscribes to all event updates.

  After subscribing, you will receive:
  - `{:event_created, %Event{}}` - When a new event is created
  - `{:event_updated, %Event{}, changes}` - When an event is updated
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    PubSub.subscribe(@pubsub, @all_events_topic)
  end

  @doc """
  Subscribes to events from a specific source.
  """
  @spec subscribe_source(String.t()) :: :ok | {:error, term()}
  def subscribe_source(source) when is_binary(source) do
    PubSub.subscribe(@pubsub, "#{@source_topic_prefix}#{source}")
  end

  @doc """
  Subscribes to updates for a specific task tree.

  You will receive updates for the parent event and all child events.
  """
  @spec subscribe_task(String.t()) :: :ok | {:error, term()}
  def subscribe_task(parent_id) when is_binary(parent_id) do
    PubSub.subscribe(@pubsub, "#{@task_topic_prefix}#{parent_id}")
  end

  @doc """
  Subscribes to updates for a specific event.

  Useful for following a single task's progress.
  """
  @spec subscribe_event(String.t()) :: :ok | {:error, term()}
  def subscribe_event(event_id) when is_binary(event_id) do
    PubSub.subscribe(@pubsub, "#{@event_topic_prefix}#{event_id}")
  end

  @doc """
  Unsubscribes from all event updates.
  """
  @spec unsubscribe() :: :ok | {:error, term()}
  def unsubscribe do
    PubSub.unsubscribe(@pubsub, @all_events_topic)
  end

  @doc """
  Unsubscribes from a specific source.
  """
  @spec unsubscribe_source(String.t()) :: :ok | {:error, term()}
  def unsubscribe_source(source) when is_binary(source) do
    PubSub.unsubscribe(@pubsub, "#{@source_topic_prefix}#{source}")
  end

  @doc """
  Unsubscribes from a specific task tree.
  """
  @spec unsubscribe_task(String.t()) :: :ok | {:error, term()}
  def unsubscribe_task(parent_id) when is_binary(parent_id) do
    PubSub.unsubscribe(@pubsub, "#{@task_topic_prefix}#{parent_id}")
  end

  @doc """
  Unsubscribes from a specific event.
  """
  @spec unsubscribe_event(String.t()) :: :ok | {:error, term()}
  def unsubscribe_event(event_id) when is_binary(event_id) do
    PubSub.unsubscribe(@pubsub, "#{@event_topic_prefix}#{event_id}")
  end
end
