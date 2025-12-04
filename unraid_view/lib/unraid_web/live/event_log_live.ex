defmodule UnraidWeb.EventLogLive do
  @moduledoc """
  Event log page displaying a real-time feed of system events and tasks.

  Features:
  - Real-time event streaming via PubSub
  - Filter by source, status, and severity
  - Search events by summary
  - Expand events to see details, links, and child events
  - Follow mode to auto-scroll to new events
  - Demo controls for generating test events
  """

  use UnraidWeb, :live_view

  alias Unraid.EventLog
  alias Unraid.EventLog.DemoGenerator

  import UnraidWeb.EventLogComponents

  @max_events 200

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:events, [])
      |> assign(:events_by_id, %{})
      |> assign(:expanded_id, nil)
      |> assign(:filters, %{source: nil, status: nil, severity: nil, search: ""})
      |> assign(:follow_mode, true)
      |> assign(:sources, [])

    if connected?(socket) do
      EventLog.subscribe()
      events = EventLog.recent(limit: 100)
      sources = events |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()
      events_by_id = Map.new(events, &{&1.id, &1})

      socket =
        socket
        |> assign(:events, events)
        |> assign(:events_by_id, events_by_id)
        |> assign(:sources, sources)

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Event Log</h1>
          <p class="text-sm text-base-content/60">
            Real-time feed of system events and tasks. {@events |> length()} events loaded.
          </p>
        </div>
      </div>

      <.filter_bar sources={@sources} filters={@filters} follow_mode={@follow_mode} />

      <.demo_controls />

      <div
        id="event-feed"
        class="space-y-3 max-h-[calc(100vh-320px)] overflow-y-auto"
        phx-hook="EventLogScroll"
        data-follow={to_string(@follow_mode)}
      >
        <div :if={filtered_events(@events, @filters) == []} class="text-center py-8 text-base-content/50">
          <.icon name="hero-inbox" class="w-12 h-12 mx-auto mb-2" />
          <p>No events match your filters</p>
        </div>

        <.event_card
          :for={event <- filtered_events(@events, @filters)}
          event={event}
          expanded={@expanded_id == event.id}
          child_events={get_child_events(@events_by_id, event.id)}
        />
      </div>
    </div>
    """
  end

  # Event handlers

  @impl true
  def handle_event("toggle_expand", %{"id" => id}, socket) do
    new_expanded =
      if socket.assigns.expanded_id == id do
        nil
      else
        id
      end

    {:noreply, assign(socket, :expanded_id, new_expanded)}
  end

  @impl true
  def handle_event("toggle_follow", _params, socket) do
    {:noreply, assign(socket, :follow_mode, !socket.assigns.follow_mode)}
  end

  @impl true
  def handle_event("filter_source", %{"source" => source}, socket) do
    source = if source == "", do: nil, else: source
    filters = %{socket.assigns.filters | source: source}
    {:noreply, assign(socket, :filters, filters)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status =
      case status do
        "" -> nil
        s -> String.to_existing_atom(s)
      end

    filters = %{socket.assigns.filters | status: status}
    {:noreply, assign(socket, :filters, filters)}
  rescue
    _ -> {:noreply, socket}
  end

  @impl true
  def handle_event("filter_severity", %{"severity" => severity}, socket) do
    severity =
      case severity do
        "" -> nil
        s -> String.to_existing_atom(s)
      end

    filters = %{socket.assigns.filters | severity: severity}
    {:noreply, assign(socket, :filters, filters)}
  rescue
    _ -> {:noreply, socket}
  end

  @impl true
  def handle_event("filter_search", %{"search" => search}, socket) do
    filters = %{socket.assigns.filters | search: search}
    {:noreply, assign(socket, :filters, filters)}
  end

  # Demo event handlers

  @impl true
  def handle_event("demo_docker_event", _params, socket) do
    DemoGenerator.generate_docker_event()
    {:noreply, socket}
  end

  @impl true
  def handle_event("demo_start_build", _params, socket) do
    DemoGenerator.start_build_task()
    {:noreply, socket}
  end

  @impl true
  def handle_event("demo_start_parity", _params, socket) do
    DemoGenerator.start_parity_check()
    {:noreply, socket}
  end

  @impl true
  def handle_event("demo_system_warning", _params, socket) do
    DemoGenerator.generate_system_warning()
    {:noreply, socket}
  end

  @impl true
  def handle_event("demo_failed_task", _params, socket) do
    DemoGenerator.generate_failed_task()
    {:noreply, socket}
  end

  # PubSub handlers

  @impl true
  def handle_info({:event_created, event}, socket) do
    socket = add_event(socket, event)

    socket =
      if socket.assigns.follow_mode do
        push_event(socket, "scroll_to_top", %{})
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:event_updated, event, _changes}, socket) do
    socket = update_event(socket, event)
    {:noreply, socket}
  end

  # Private helpers

  defp add_event(socket, event) do
    events = [event | socket.assigns.events] |> Enum.take(@max_events)
    events_by_id = Map.put(socket.assigns.events_by_id, event.id, event)

    # Update sources list if new source
    sources =
      if event.source in socket.assigns.sources do
        socket.assigns.sources
      else
        [event.source | socket.assigns.sources] |> Enum.sort()
      end

    socket
    |> assign(:events, events)
    |> assign(:events_by_id, events_by_id)
    |> assign(:sources, sources)
  end

  defp update_event(socket, event) do
    events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == event.id, do: event, else: e
      end)

    events_by_id = Map.put(socket.assigns.events_by_id, event.id, event)

    socket
    |> assign(:events, events)
    |> assign(:events_by_id, events_by_id)
  end

  defp filtered_events(events, filters) do
    events
    |> filter_top_level()
    |> filter_by_source(filters.source)
    |> filter_by_status(filters.status)
    |> filter_by_severity(filters.severity)
    |> filter_by_search(filters.search)
  end

  # Hide child events from the main feed - they appear in parent's timeline
  defp filter_top_level(events) do
    Enum.filter(events, &is_nil(&1.parent_id))
  end

  defp filter_by_source(events, nil), do: events
  defp filter_by_source(events, source), do: Enum.filter(events, &(&1.source == source))

  defp filter_by_status(events, nil), do: events
  defp filter_by_status(events, status), do: Enum.filter(events, &(&1.status == status))

  defp filter_by_severity(events, nil), do: events
  defp filter_by_severity(events, severity), do: Enum.filter(events, &(&1.severity == severity))

  defp filter_by_search(events, ""), do: events
  defp filter_by_search(events, nil), do: events

  defp filter_by_search(events, search) do
    search = String.downcase(search)

    Enum.filter(events, fn event ->
      String.contains?(String.downcase(event.summary), search) ||
        String.contains?(String.downcase(event.source), search) ||
        String.contains?(String.downcase(event.category), search)
    end)
  end

  defp get_child_events(events_by_id, parent_id) do
    events_by_id
    |> Map.values()
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
  end
end
