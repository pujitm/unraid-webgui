defmodule Unraid.Log.LogMonitorServer do
  @moduledoc """
  GenServer that monitors a single file for changes and broadcasts
  new lines with byte offsets to subscribers.

  ## Line Format
  Lines are sent as maps:
      %{offset: byte_offset, text: "line content"}

  ## Messages to Subscribers
  - `{:log_lines, path, [%{offset: n, text: "..."}]}` - New lines
  - `{:log_reset, path}` - File was truncated/rotated
  """
  use GenServer
  require Logger

  alias Unraid.FileExtras

  @registry Unraid.Log.Registry
  @supervisor Unraid.Log.MonitorDynamicSupervisor

  @default_poll_interval 500
  @default_initial_lines 200

  defp poll_interval do
    Application.get_env(:unraid, :log_monitor_poll_interval, @default_poll_interval)
  end

  defstruct [
    :path,
    :offset,
    :file_size,
    :subscribers,
    :poll_timer,
    :pending_line
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Subscribe to a file. Starts the monitor if not running.

  ## Options
  - `:initial_lines` - Number of recent lines to return (default: #{@default_initial_lines})

  ## Returns
  `{:ok, pid, initial_lines}` where initial_lines is a list of
  `%{offset: n, text: "..."}` maps in chronological order (oldest first).
  """
  @spec subscribe(Path.t(), keyword()) :: {:ok, pid(), [map()]} | {:error, term()}
  def subscribe(path, opts \\ []) do
    path = Path.expand(path)
    initial_lines = Keyword.get(opts, :initial_lines, @default_initial_lines)

    case ensure_started(path) do
      {:ok, pid} ->
        lines = GenServer.call(pid, {:subscribe, initial_lines})
        {:ok, pid, lines}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unsubscribe from file updates.
  """
  @spec unsubscribe(Path.t()) :: :ok
  def unsubscribe(path) do
    path = Path.expand(path)

    case find_server(path) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:unsubscribe, self()})
    end
  end

  @doc """
  Load historical lines before a given byte offset.

  Returns lines whose start offset is less than `before_offset`.

  ## Returns
  `{lines, earliest_offset}` where lines is in chronological order (oldest first)
  """
  @spec load_history(Path.t(), non_neg_integer(), non_neg_integer()) ::
          {[map()], non_neg_integer()}
  def load_history(path, before_offset, count \\ 100) do
    path = Path.expand(path)

    # Read lines backwards from before_offset, then reverse to chronological order
    lines =
      path
      |> FileExtras.stream_reverse(before_offset)
      |> Enum.take(count)
      |> Enum.reverse()
      |> Enum.map(fn {offset, text} -> %{offset: offset, text: text} end)

    earliest_offset =
      case lines do
        [] -> 0
        [%{offset: offset} | _] -> offset
      end

    {lines, earliest_offset}
  end

  @doc """
  Get current monitor info.
  """
  @spec get_info(Path.t()) :: map() | nil
  def get_info(path) do
    path = Path.expand(path)

    case find_server(path) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, :get_info)
        catch
          :exit, _ -> nil
        end
    end
  end

  def start_link(path) do
    name = via_tuple(path)
    GenServer.start_link(__MODULE__, path, name: name)
  end

  def child_spec(path) do
    %{
      id: {__MODULE__, path},
      start: {__MODULE__, :start_link, [path]},
      restart: :temporary
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp ensure_started(path) do
    case find_server(path) do
      nil ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, path}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp find_server(path) do
    GenServer.whereis(via_tuple(path))
  end

  defp via_tuple(path) do
    {:via, Registry, {@registry, {__MODULE__, path}}}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(path) do
    # Get current file size - we start at EOF (tail mode)
    {offset, file_size} =
      case FileExtras.file_size(path) do
        {:ok, size} -> {size, size}
        {:error, _} -> {0, 0}
      end

    state = %__MODULE__{
      path: path,
      offset: offset,
      file_size: file_size,
      subscribers: [],
      poll_timer: nil,
      pending_line: ""
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, initial_lines_count}, {from_pid, _tag}, state) do
    Process.monitor(from_pid)

    # Load initial lines using stream_reverse
    initial_lines =
      state.path
      |> FileExtras.stream_reverse()
      |> Enum.take(initial_lines_count)
      |> Enum.reverse()
      |> Enum.map(fn {offset, text} -> %{offset: offset, text: text} end)

    # Start polling if not already running
    state =
      if state.poll_timer == nil do
        timer = Process.send_after(self(), :poll, poll_interval())
        %{state | poll_timer: timer}
      else
        state
      end

    new_subscribers = [from_pid | state.subscribers]
    {:reply, initial_lines, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      path: state.path,
      offset: state.offset,
      file_size: state.file_size,
      subscriber_count: length(state.subscribers)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    maybe_stop_if_no_subscribers(%{state | subscribers: subscribers})
  end

  @impl true
  def handle_info(:poll, state) do
    state = check_for_updates(state)

    # Schedule next poll if we still have subscribers
    state =
      if state.subscribers != [] do
        timer = Process.send_after(self(), :poll, poll_interval())
        %{state | poll_timer: timer}
      else
        %{state | poll_timer: nil}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    maybe_stop_if_no_subscribers(%{state | subscribers: subscribers})
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp check_for_updates(state) do
    case FileExtras.file_size(state.path) do
      {:ok, size} when size > state.offset ->
        # New data available
        read_new_data(state, size)

      {:ok, size} when size < state.offset ->
        # File was truncated
        handle_truncation(state, size)

      _ ->
        # No change or error
        state
    end
  end

  defp read_new_data(state, new_size) do
    case FileExtras.read_from(state.path, state.offset) do
      {:ok, data} when byte_size(data) > 0 ->
        {lines, new_pending} = parse_new_data(state.pending_line <> data, state.offset)

        if lines != [] do
          broadcast(state.subscribers, {:log_lines, state.path, lines})
        end

        %{state | offset: new_size, file_size: new_size, pending_line: new_pending}

      _ ->
        %{state | file_size: new_size}
    end
  end

  defp handle_truncation(state, new_size) do
    broadcast(state.subscribers, {:log_reset, state.path})

    # Reset to beginning or new size
    %{state | offset: new_size, file_size: new_size, pending_line: ""}
  end

  # Parse new data into lines with offsets
  # Returns {lines, pending} where pending is incomplete line at end
  defp parse_new_data(data, base_offset) do
    parts = String.split(data, "\n")

    case parts do
      [single] ->
        # No complete line yet
        {[], single}

      _ ->
        {complete_parts, [pending]} = Enum.split(parts, -1)
        lines = build_lines_forward(complete_parts, base_offset)
        {lines, pending}
    end
  end

  # Build lines with offsets going forward (for new data)
  defp build_lines_forward(parts, base_offset) do
    {lines, _} =
      Enum.reduce(parts, {[], base_offset}, fn part, {acc, offset} ->
        line = %{offset: offset, text: String.trim_trailing(part, "\r")}
        new_offset = offset + byte_size(part) + 1
        {[line | acc], new_offset}
      end)

    Enum.reverse(lines)
  end

  defp broadcast(subscribers, message) do
    Enum.each(subscribers, fn pid -> send(pid, message) end)
  end

  defp maybe_stop_if_no_subscribers(%{subscribers: []} = state) do
    # Cancel poll timer if running
    if state.poll_timer do
      Process.cancel_timer(state.poll_timer)
    end

    {:stop, :normal, %{state | poll_timer: nil}}
  end

  defp maybe_stop_if_no_subscribers(state) do
    {:noreply, state}
  end
end
