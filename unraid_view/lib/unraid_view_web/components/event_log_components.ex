defmodule UnraidViewWeb.EventLogComponents do
  @moduledoc """
  UI components for the event log system.
  """

  use Phoenix.Component

  import UnraidViewWeb.CoreComponents, only: [icon: 1]

  alias UnraidView.EventLog.Event

  @doc """
  Renders an event card. If the event has children, it renders as a collapsible timeline.
  """
  attr :event, Event, required: true
  attr :expanded, :boolean, default: false
  attr :child_events, :list, default: []

  def event_card(assigns) do
    has_children = assigns.child_events != []
    assigns = assign(assigns, :has_children, has_children)

    ~H"""
    <div
      id={"event-#{@event.id}"}
      class={[
        "card card-compact bg-base-100 border transition-all",
        severity_border_class(@event.severity),
        @expanded && "ring-2 ring-primary/30"
      ]}
    >
      <div class="card-body">
        <%!-- Main event header - always clickable --%>
        <div
          class="flex items-center gap-3 cursor-pointer"
          phx-click="toggle_expand"
          phx-value-id={@event.id}
        >
          <.source_icon source={@event.source} />
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <p class="font-medium truncate">{@event.summary}</p>
              <span :if={@has_children} class="badge badge-xs badge-ghost">
                {length(@child_events)} steps
              </span>
            </div>
            <p class="text-xs text-base-content/60">
              {format_timestamp(@event.timestamp)} &bull; {@event.source}/{@event.category}
            </p>
          </div>
          <.progress_indicator :if={@event.progress && @event.status == :running} value={@event.progress} />
          <.status_badge status={@event.status} />
          <.severity_badge severity={@event.severity} />
          <.icon
            name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="w-4 h-4 text-base-content/40"
          />
        </div>

        <%!-- Expanded content --%>
        <div :if={@expanded} class="mt-4 space-y-4">
          <%!-- Progress bar for running tasks --%>
          <.progress_bar :if={@event.progress} value={@event.progress} />

          <%!-- Timeline for events with children --%>
          <.event_timeline :if={@has_children} event={@event} children={@child_events} />

          <%!-- Links section --%>
          <.links_list :if={@event.links != []} links={@event.links} />

          <%!-- Metadata section --%>
          <.metadata_display :if={@event.metadata != %{}} metadata={@event.metadata} />

          <%!-- Event details footer --%>
          <div class="text-xs text-base-content/50 space-y-1 pt-2 border-t border-base-200">
            <p>ID: <code class="bg-base-200 px-1 rounded">{@event.id}</code></p>
            <p :if={@event.parent_id}>
              Parent: <code class="bg-base-200 px-1 rounded">{@event.parent_id}</code>
            </p>
            <p :if={@event.started_at}>Started: {format_datetime(@event.started_at)}</p>
            <p :if={@event.completed_at}>Completed: {format_datetime(@event.completed_at)}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a timeline view of an event and its children.
  """
  attr :event, Event, required: true
  attr :children, :list, required: true

  def event_timeline(assigns) do
    ~H"""
    <div class="space-y-0">
      <p class="text-xs font-medium text-base-content/60 mb-2">Timeline</p>
      <ul class="timeline timeline-vertical timeline-compact">
        <%!-- Parent event as first timeline item --%>
        <li>
          <div class="timeline-start text-xs text-base-content/50 w-16 text-right">
            {format_time_only(@event.timestamp)}
          </div>
          <div class={["timeline-middle", timeline_dot_class(@event.status)]}>
            <.timeline_icon status={@event.status} />
          </div>
          <div class="timeline-end timeline-box bg-base-200/50 py-2 px-3">
            <div class="flex items-center gap-2">
              <span class="font-medium text-sm">Started</span>
              <.status_badge status={@event.status} />
            </div>
            <p class="text-xs text-base-content/60 mt-1">{@event.summary}</p>
          </div>
          <hr class={timeline_line_class(length(@children) > 0)} />
        </li>

        <%!-- Child events --%>
        <li :for={{child, idx} <- Enum.with_index(@children)}>
          <hr class={timeline_line_class(true)} />
          <div class="timeline-start text-xs text-base-content/50 w-16 text-right">
            {format_time_only(child.timestamp)}
          </div>
          <div class={["timeline-middle", timeline_dot_class(child.status)]}>
            <.timeline_icon status={child.status} />
          </div>
          <div class="timeline-end timeline-box py-2 px-3">
            <div class="flex items-center gap-2">
              <span class="text-sm">{child.summary}</span>
              <.status_badge status={child.status} />
            </div>
            <div :if={child.links != []} class="flex flex-wrap gap-1 mt-1">
              <span
                :for={link <- child.links}
                class="badge badge-xs badge-outline gap-1"
              >
                <.link_icon type={link.type} />
                {link.label}
              </span>
            </div>
          </div>
          <hr :if={idx < length(@children) - 1 || @event.status == :running} class={timeline_line_class(true)} />
        </li>

        <%!-- Completion/current status item --%>
        <li :if={@event.status in [:completed, :failed, :cancelled]}>
          <hr class={timeline_line_class(true)} />
          <div class="timeline-start text-xs text-base-content/50 w-16 text-right">
            {format_time_only(@event.completed_at)}
          </div>
          <div class={["timeline-middle", timeline_dot_class(@event.status)]}>
            <.timeline_icon status={@event.status} />
          </div>
          <div class={[
            "timeline-end timeline-box py-2 px-3",
            @event.status == :completed && "bg-success/10",
            @event.status == :failed && "bg-error/10",
            @event.status == :cancelled && "bg-warning/10"
          ]}>
            <div class="flex items-center gap-2">
              <span class="font-medium text-sm">
                {status_label(@event.status)}
              </span>
              <.status_badge status={@event.status} />
            </div>
            <p :if={@event.status == :completed} class="text-xs text-success mt-1">
              Completed in {format_duration(@event.started_at, @event.completed_at)}
            </p>
          </div>
        </li>

        <%!-- Running indicator --%>
        <li :if={@event.status == :running}>
          <hr class="bg-info" />
          <div class="timeline-start text-xs text-base-content/50 w-16 text-right">
            now
          </div>
          <div class="timeline-middle text-info">
            <span class="loading loading-spinner loading-xs"></span>
          </div>
          <div class="timeline-end timeline-box py-2 px-3 bg-info/10 border-info/30">
            <span class="text-sm text-info font-medium">In progress...</span>
            <span :if={@event.progress} class="text-xs text-info/70 ml-2">{@event.progress}%</span>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders a filter bar for the event log.
  """
  attr :sources, :list, default: []
  attr :filters, :map, required: true
  attr :follow_mode, :boolean, default: true

  def filter_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-3 items-center p-4 bg-base-200 rounded-lg">
      <select
        class="select select-sm select-bordered"
        phx-change="filter_source"
        name="source"
      >
        <option value="" selected={@filters.source == nil}>All Sources</option>
        <option :for={source <- @sources} value={source} selected={@filters.source == source}>
          {source}
        </option>
      </select>

      <select
        class="select select-sm select-bordered"
        phx-change="filter_status"
        name="status"
      >
        <option value="" selected={@filters.status == nil}>All Statuses</option>
        <option value="pending" selected={@filters.status == :pending}>Pending</option>
        <option value="running" selected={@filters.status == :running}>Running</option>
        <option value="completed" selected={@filters.status == :completed}>Completed</option>
        <option value="failed" selected={@filters.status == :failed}>Failed</option>
        <option value="cancelled" selected={@filters.status == :cancelled}>Cancelled</option>
      </select>

      <select
        class="select select-sm select-bordered"
        phx-change="filter_severity"
        name="severity"
      >
        <option value="" selected={@filters.severity == nil}>All Severities</option>
        <option value="debug" selected={@filters.severity == :debug}>Debug</option>
        <option value="info" selected={@filters.severity == :info}>Info</option>
        <option value="notice" selected={@filters.severity == :notice}>Notice</option>
        <option value="warning" selected={@filters.severity == :warning}>Warning</option>
        <option value="error" selected={@filters.severity == :error}>Error</option>
      </select>

      <input
        type="text"
        class="input input-sm input-bordered w-48"
        placeholder="Search..."
        phx-change="filter_search"
        phx-debounce="300"
        name="search"
        value={@filters.search}
      />

      <div class="flex-1" />

      <label class="label cursor-pointer gap-2">
        <span class="label-text text-sm">Follow</span>
        <input
          type="checkbox"
          class="toggle toggle-sm toggle-primary"
          checked={@follow_mode}
          phx-click="toggle_follow"
        />
      </label>
    </div>
    """
  end

  @doc """
  Renders demo controls for generating test events.
  """
  def demo_controls(assigns) do
    ~H"""
    <div class="card bg-warning/10 border border-warning/30">
      <div class="card-body p-4">
        <h3 class="font-semibold text-sm mb-2 flex items-center gap-2">
          <.icon name="hero-beaker" class="w-4 h-4" />
          Demo Controls
        </h3>
        <div class="flex flex-wrap gap-2">
          <button class="btn btn-sm btn-outline" phx-click="demo_docker_event">
            <.icon name="hero-cube" class="w-4 h-4" />
            Docker Event
          </button>
          <button class="btn btn-sm btn-outline" phx-click="demo_start_build">
            <.icon name="hero-wrench-screwdriver" class="w-4 h-4" />
            Start Build Task
          </button>
          <button class="btn btn-sm btn-outline" phx-click="demo_start_parity">
            <.icon name="hero-shield-check" class="w-4 h-4" />
            Start Parity Check
          </button>
          <button class="btn btn-sm btn-outline btn-warning" phx-click="demo_system_warning">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
            System Warning
          </button>
          <button class="btn btn-sm btn-outline btn-error" phx-click="demo_failed_task">
            <.icon name="hero-x-circle" class="w-4 h-4" />
            Failed Task
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a status badge.
  """
  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_badge_class(@status)]}>
      {@status}
    </span>
    """
  end

  @doc """
  Renders a severity badge.
  """
  attr :severity, :atom, required: true

  def severity_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm badge-outline", severity_badge_class(@severity)]}>
      {@severity}
    </span>
    """
  end

  @doc """
  Renders a small circular progress indicator for the header.
  """
  attr :value, :integer, required: true

  def progress_indicator(assigns) do
    ~H"""
    <div class="radial-progress text-primary text-xs" style={"--value:#{@value}; --size:1.5rem; --thickness:2px;"} role="progressbar">
      <span class="text-[8px]">{@value}</span>
    </div>
    """
  end

  @doc """
  Renders a progress bar.
  """
  attr :value, :integer, required: true

  def progress_bar(assigns) do
    ~H"""
    <div class="w-full">
      <div class="flex justify-between text-xs text-base-content/60 mb-1">
        <span>Progress</span>
        <span>{@value}%</span>
      </div>
      <progress class="progress progress-primary w-full" value={@value} max="100" />
    </div>
    """
  end

  @doc """
  Renders a list of links attached to an event.
  """
  attr :links, :list, required: true

  def links_list(assigns) do
    ~H"""
    <div class="space-y-1">
      <p class="text-xs font-medium text-base-content/60">Attachments</p>
      <div class="flex flex-wrap gap-2">
        <div
          :for={link <- @links}
          class="badge badge-outline gap-1 cursor-pointer hover:bg-base-200"
        >
          <.link_icon type={link.type} />
          <span>{link.label}</span>
          <span :if={link.tailable} class="text-xs text-success">(live)</span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders event metadata as a simple key-value list.
  """
  attr :metadata, :map, required: true

  def metadata_display(assigns) do
    ~H"""
    <div class="space-y-1">
      <p class="text-xs font-medium text-base-content/60">Metadata</p>
      <div class="bg-base-200 rounded p-2 text-xs font-mono overflow-x-auto">
        <div :for={{key, value} <- @metadata} class="flex gap-2">
          <span class="text-primary">{key}:</span>
          <span class="text-base-content/80">{inspect(value)}</span>
        </div>
      </div>
    </div>
    """
  end

  # Private helper components

  defp source_icon(assigns) do
    icon_name =
      case assigns.source do
        "docker" -> "hero-cube"
        "vm" -> "hero-computer-desktop"
        "system" -> "hero-server"
        "array" -> "hero-circle-stack"
        "network" -> "hero-globe-alt"
        _ -> "hero-bolt"
      end

    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <div class={["p-2 rounded-lg", source_bg_class(@source)]}>
      <.icon name={@icon_name} class="w-5 h-5" />
    </div>
    """
  end

  defp link_icon(assigns) do
    icon_name =
      case assigns.type do
        :log_file -> "hero-document-text"
        :url -> "hero-link"
        :terminal -> "hero-command-line"
        :container -> "hero-cube"
        _ -> "hero-link"
      end

    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <.icon name={@icon_name} class="w-3 h-3" />
    """
  end

  defp timeline_icon(assigns) do
    ~H"""
    <span :if={@status == :completed} class="text-success">
      <.icon name="hero-check-circle-solid" class="w-4 h-4" />
    </span>
    <span :if={@status == :failed} class="text-error">
      <.icon name="hero-x-circle-solid" class="w-4 h-4" />
    </span>
    <span :if={@status == :cancelled} class="text-warning">
      <.icon name="hero-minus-circle-solid" class="w-4 h-4" />
    </span>
    <span :if={@status == :running} class="text-info">
      <.icon name="hero-play-circle-solid" class="w-4 h-4" />
    </span>
    <span :if={@status == :pending} class="text-base-content/40">
      <.icon name="hero-clock" class="w-4 h-4" />
    </span>
    """
  end

  # Styling helpers

  defp severity_border_class(severity) do
    case severity do
      :error -> "border-error/50"
      :warning -> "border-warning/50"
      :notice -> "border-info/50"
      _ -> "border-base-300"
    end
  end

  defp status_badge_class(status) do
    case status do
      :pending -> "badge-ghost"
      :running -> "badge-info"
      :completed -> "badge-success"
      :failed -> "badge-error"
      :cancelled -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  defp severity_badge_class(severity) do
    case severity do
      :error -> "border-error text-error"
      :warning -> "border-warning text-warning"
      :notice -> "border-info text-info"
      :info -> "border-base-content/30 text-base-content/60"
      :debug -> "border-base-content/20 text-base-content/40"
      _ -> "border-base-content/30"
    end
  end

  defp source_bg_class(source) do
    case source do
      "docker" -> "bg-blue-500/10 text-blue-600"
      "vm" -> "bg-purple-500/10 text-purple-600"
      "system" -> "bg-gray-500/10 text-gray-600"
      "array" -> "bg-green-500/10 text-green-600"
      "network" -> "bg-orange-500/10 text-orange-600"
      _ -> "bg-base-200 text-base-content/60"
    end
  end

  defp timeline_dot_class(status) do
    case status do
      :completed -> "text-success"
      :failed -> "text-error"
      :cancelled -> "text-warning"
      :running -> "text-info"
      _ -> "text-base-content/40"
    end
  end

  defp timeline_line_class(true), do: "bg-base-300"
  defp timeline_line_class(false), do: "bg-transparent"

  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(status), do: to_string(status)

  # Formatting helpers

  defp format_timestamp(nil), do: ""

  defp format_timestamp(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(datetime, "%b %d, %H:%M")
    end
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_time_only(nil), do: ""

  defp format_time_only(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_duration(nil, _), do: "unknown"
  defp format_duration(_, nil), do: "unknown"

  defp format_duration(started, completed) do
    seconds = DateTime.diff(completed, started, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
    end
  end
end
