defmodule Unraid.Docker.EventsServer do
  @moduledoc """
  Streams Docker events via `docker events` CLI.

  Listens for container lifecycle events (start, stop, die, pause, unpause, destroy)
  and broadcasts them via PubSub. This enables instant UI updates when container
  state changes, without polling.

  ## Event Format

  Each broadcast contains an event map:

      %{action: "start", container_id: "abc123def456"}

  ## Supported Actions

    * `start` - Container started
    * `stop` - Container stopped
    * `die` - Container died (crashed)
    * `pause` - Container paused
    * `unpause` - Container resumed
    * `destroy` - Container removed
    * `create` - Container created

  ## Restart Behavior

  If the docker events process exits (e.g., Docker daemon restart),
  this GenServer will automatically restart the stream after a brief delay.
  """

  use GenServer
  require Logger

  alias Unraid.Docker
  alias Unraid.Docker.Adapter

  @relevant_actions ~w(start stop die pause unpause destroy create kill restart)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{port: nil, buffer: ""}, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    case Adapter.open_events_port() do
      {:ok, port} ->
        {:noreply, %{state | port: port, buffer: ""}}

      {:error, reason} ->
        Logger.warning("[EventsServer] Failed to start docker events: #{inspect(reason)}")
        schedule_restart()
        {:noreply, %{state | port: nil, buffer: ""}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, buffer: buffer} = state) do
    {lines, new_buffer} = extract_lines(buffer <> data)

    Enum.each(lines, fn line ->
      case parse_event_line(line) do
        {:ok, event} -> handle_docker_event(event)
        :ignore -> :ok
        {:error, _} -> :ok
      end
    end)

    {:noreply, %{state | buffer: new_buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[EventsServer] docker events exited with status #{status}")
    schedule_restart()
    {:noreply, %{state | port: nil, buffer: ""}}
  end

  @impl true
  def handle_info(:restart_stream, state) do
    {:noreply, state, {:continue, :start_stream}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when not is_nil(port) do
    Port.close(port)
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp schedule_restart do
    Process.send_after(self(), :restart_stream, 5_000)
  end

  defp extract_lines(buffer) do
    lines = String.split(buffer, "\n")

    case List.pop_at(lines, -1) do
      {nil, []} -> {[], ""}
      {incomplete, complete} -> {complete, incomplete || ""}
    end
  end

  defp parse_event_line(line) do
    line = String.trim(line)

    if line == "" do
      :ignore
    else
      case Jason.decode(line) do
        {:ok, event} -> {:ok, event}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp handle_docker_event(%{"Action" => action, "Actor" => %{"ID" => id}})
       when action in @relevant_actions do
    Docker.broadcast_event(%{
      action: action,
      container_id: String.slice(id, 0, 12)
    })
  end

  defp handle_docker_event(%{"status" => action, "id" => id})
       when action in @relevant_actions do
    # Alternative format from some Docker versions
    Docker.broadcast_event(%{
      action: action,
      container_id: String.slice(id, 0, 12)
    })
  end

  defp handle_docker_event(_event), do: :ok
end
