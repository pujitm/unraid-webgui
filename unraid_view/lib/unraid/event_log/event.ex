defmodule Unraid.EventLog.Event do
  @moduledoc """
  Represents an event in the append-only event log.

  Events can be simple notifications or long-running tasks with progress tracking.
  They support hierarchical relationships via `parent_id` and can link to external
  resources like log files or URLs.
  """

  @type severity :: :debug | :info | :notice | :warning | :error
  @type status :: :pending | :running | :completed | :failed | :cancelled

  @type link :: %{
          type: :log_file | :url | :terminal | :container,
          label: String.t(),
          target: String.t(),
          tailable: boolean()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          timestamp: DateTime.t(),
          source: String.t(),
          category: String.t(),
          summary: String.t(),
          severity: severity(),
          status: status(),
          parent_id: String.t() | nil,
          progress: integer() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          links: [link()],
          metadata: map(),
          execution_context: map() | nil
        }

  @derive {Jason.Encoder,
           only: [
             :id,
             :timestamp,
             :source,
             :category,
             :summary,
             :severity,
             :status,
             :parent_id,
             :progress,
             :started_at,
             :completed_at,
             :links,
             :metadata,
             :execution_context
           ]}

  defstruct [
    :id,
    :timestamp,
    :source,
    :category,
    :summary,
    :severity,
    :status,
    :parent_id,
    :progress,
    :started_at,
    :completed_at,
    :execution_context,
    links: [],
    metadata: %{}
  ]

  @severities [:debug, :info, :notice, :warning, :error]
  @statuses [:pending, :running, :completed, :failed, :cancelled]

  @doc """
  Creates a new event from the given attributes.

  Required fields:
  - `:source` - Origin module/subsystem (e.g., "docker", "system")
  - `:category` - Event category (e.g., "container.start")
  - `:summary` - Human-readable one-line summary

  Optional fields:
  - `:severity` - defaults to `:info`
  - `:status` - defaults to `:completed`
  - `:parent_id` - for hierarchical tasks
  - `:progress` - 0-100 percentage
  - `:links` - list of link maps
  - `:metadata` - arbitrary map
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, source} <- require_field(attrs, :source),
         {:ok, category} <- require_field(attrs, :category),
         {:ok, summary} <- require_field(attrs, :summary),
         {:ok, severity} <- validate_severity(attrs[:severity] || :info),
         {:ok, status} <- validate_status(attrs[:status] || :completed),
         {:ok, progress} <- validate_progress(attrs[:progress]),
         {:ok, links} <- validate_links(attrs[:links] || []) do
      now = DateTime.utc_now()

      event = %__MODULE__{
        id: generate_id(),
        timestamp: now,
        source: to_string(source),
        category: to_string(category),
        summary: to_string(summary),
        severity: severity,
        status: status,
        parent_id: attrs[:parent_id],
        progress: progress,
        started_at: if(status == :running, do: now, else: attrs[:started_at]),
        completed_at: if(status in [:completed, :failed, :cancelled], do: now, else: nil),
        links: links,
        metadata: attrs[:metadata] || %{},
        execution_context: attrs[:execution_context]
      }

      {:ok, event}
    end
  end

  @doc """
  Updates an existing event with new attributes.

  Returns the updated event and a map of changes for PubSub broadcasting.
  """
  @spec update(t(), map()) :: {:ok, t(), map()} | {:error, term()}
  def update(%__MODULE__{} = event, attrs) when is_map(attrs) do
    changes = %{}

    {event, changes} =
      Enum.reduce(attrs, {event, changes}, fn
        {:status, value}, {e, c} ->
          case validate_status(value) do
            {:ok, status} ->
              e = %{e | status: status}

              e =
                if status in [:completed, :failed, :cancelled] and is_nil(e.completed_at) do
                  %{e | completed_at: DateTime.utc_now()}
                else
                  e
                end

              {e, Map.put(c, :status, status)}

            _ ->
              {e, c}
          end

        {:progress, value}, {e, c} ->
          case validate_progress(value) do
            {:ok, progress} ->
              {%{e | progress: progress}, Map.put(c, :progress, progress)}

            _ ->
              {e, c}
          end

        {:summary, value}, {e, c} when is_binary(value) ->
          {%{e | summary: value}, Map.put(c, :summary, value)}

        {:metadata, value}, {e, c} when is_map(value) ->
          merged = Map.merge(e.metadata, value)
          {%{e | metadata: merged}, Map.put(c, :metadata, merged)}

        _, acc ->
          acc
      end)

    {:ok, event, changes}
  end

  @doc """
  Adds a link to an existing event.
  """
  @spec add_link(t(), map()) :: {:ok, t(), map()} | {:error, term()}
  def add_link(%__MODULE__{} = event, link_attrs) when is_map(link_attrs) do
    link = %{
      type: link_attrs[:type] || :url,
      label: to_string(link_attrs[:label] || "Link"),
      target: to_string(link_attrs[:target] || ""),
      tailable: link_attrs[:tailable] || false
    }

    updated_links = event.links ++ [link]
    updated_event = %{event | links: updated_links}
    {:ok, updated_event, %{links: [link]}}
  end

  @doc """
  Decodes an event from a JSON map (as read from file).
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_map(json) do
    event = %__MODULE__{
      id: json["id"],
      timestamp: parse_datetime(json["timestamp"]),
      source: json["source"],
      category: json["category"],
      summary: json["summary"],
      severity: parse_atom(json["severity"], @severities, :info),
      status: parse_atom(json["status"], @statuses, :completed),
      parent_id: json["parent_id"],
      progress: json["progress"],
      started_at: parse_datetime(json["started_at"]),
      completed_at: parse_datetime(json["completed_at"]),
      links: parse_links(json["links"] || []),
      metadata: json["metadata"] || %{},
      execution_context: json["execution_context"]
    }

    {:ok, event}
  rescue
    _ -> {:error, :invalid_json}
  end

  # Private helpers

  defp generate_id do
    # Generate a time-sortable ID (UUID v7-like)
    # Format: timestamp_ms (48 bits) + random (80 bits), base62 encoded
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(10)

    <<timestamp::48, random::binary-size(10)>>
    |> Base.encode16(case: :lower)
  end

  defp require_field(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:error, {:missing_field, field}}
      "" -> {:error, {:empty_field, field}}
      value -> {:ok, value}
    end
  end

  defp validate_severity(value) when value in @severities, do: {:ok, value}

  defp validate_severity(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    validate_severity(atom)
  rescue
    _ -> {:error, {:invalid_severity, value}}
  end

  defp validate_severity(value), do: {:error, {:invalid_severity, value}}

  defp validate_status(value) when value in @statuses, do: {:ok, value}

  defp validate_status(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    validate_status(atom)
  rescue
    _ -> {:error, {:invalid_status, value}}
  end

  defp validate_status(value), do: {:error, {:invalid_status, value}}

  defp validate_progress(nil), do: {:ok, nil}
  defp validate_progress(p) when is_integer(p) and p >= 0 and p <= 100, do: {:ok, p}
  defp validate_progress(p), do: {:error, {:invalid_progress, p}}

  defp validate_links(links) when is_list(links) do
    {:ok,
     Enum.map(links, fn link ->
       %{
         type: link[:type] || :url,
         label: to_string(link[:label] || "Link"),
         target: to_string(link[:target] || ""),
         tailable: link[:tailable] || false
       }
     end)}
  end

  defp validate_links(_), do: {:error, :invalid_links}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_atom(nil, _valid, default), do: default
  defp parse_atom(value, valid, default) when is_atom(value) do
    if value in valid, do: value, else: default
  end
  defp parse_atom(value, valid, default) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in valid, do: atom, else: default
  rescue
    _ -> default
  end

  defp parse_links(links) when is_list(links) do
    Enum.map(links, fn link ->
      %{
        type: parse_atom(link["type"], [:log_file, :url, :terminal, :container], :url),
        label: link["label"] || "Link",
        target: link["target"] || "",
        tailable: link["tailable"] || false
      }
    end)
  end

  defp parse_links(_), do: []
end
