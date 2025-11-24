defmodule UnraidViewWeb.EventDemoLive do
  @moduledoc """
  Demo page showcasing the `data-on-<event>` pattern.

  This pattern allows declarative binding of Phoenix.LiveView.JS commands to
  phx:* events dispatched via window.dispatchEvent. The app.js patch intercepts
  these events and executes the JS commands on elements with matching
  `data-on-<event_name>` attributes.

  For example:
    <div data-on-my_event={JS.show()}>Hidden until my_event fires</div>

  When push_event(socket, "my_event", %{}) is called, the patched dispatchEvent
  fires `phx:my_event`, and the JS.show() command runs on that element.
  """
  use Phoenix.LiveView
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       counter: 0,
       last_action: nil,
       notification_count: 0
     )}
  end

  @impl true
  def handle_event("trigger_success", _params, socket) do
    {:noreply,
     socket
     |> assign(:last_action, :success)
     |> push_event("action_success", %{message: "Operation completed!"})}
  end

  @impl true
  def handle_event("trigger_error", _params, socket) do
    {:noreply,
     socket
     |> assign(:last_action, :error)
     |> push_event("action_error", %{message: "Something went wrong!"})}
  end

  @impl true
  def handle_event("trigger_warning", _params, socket) do
    {:noreply,
     socket
     |> assign(:last_action, :warning)
     |> push_event("action_warning", %{message: "Proceed with caution!"})}
  end

  @impl true
  def handle_event("trigger_notification", _params, socket) do
    count = socket.assigns.notification_count + 1

    {:noreply,
     socket
     |> assign(:notification_count, count)
     |> push_event("new_notification", %{count: count})}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    new_count = socket.assigns.counter + 1

    socket =
      socket
      |> assign(:counter, new_count)
      |> push_event("counter_changed", %{value: new_count})

    socket =
      if rem(new_count, 5) == 0 do
        push_event(socket, "milestone_reached", %{value: new_count})
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:counter, 0)
     |> assign(:notification_count, 0)
     |> push_event("counter_reset", %{})}
  end

  @impl true
  def handle_event("dismiss_all", _params, socket) do
    {:noreply, push_event(socket, "dismiss_notifications", %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-6 max-w-4xl">
      <h1 class="text-3xl font-bold mb-2">data-on-&lt;event&gt; Pattern Demo</h1>
      <p class="text-base-content/70 mb-8">
        This demo showcases the <code class="badge badge-ghost">data-on-&lt;event&gt;</code>
        pattern enabled by the dispatchEvent patch in app.js. Click the buttons to trigger
        server events that push client-side events, which are then handled declaratively
        via <code class="badge badge-ghost">Phoenix.LiveView.JS</code> commands.
      </p>

      <div class="grid gap-6 md:grid-cols-2">
        <%!-- Section 1: Toast Notifications --%>
        <div class="card bg-base-100 shadow-xl card-border border-primary">
          <div class="card-body">
            <h2 class="card-title">Toast Notifications</h2>
            <p class="text-sm text-base-content/70 mb-4">
              Click buttons to trigger events. The toasts appear using
              <code>data-on-action_*</code> attributes with <code>JS.show()</code>.
            </p>

            <div class="flex flex-wrap gap-2">
              <button class="btn btn-success btn-sm" phx-click="trigger_success">
                Success
              </button>
              <button class="btn btn-error btn-sm" phx-click="trigger_error">
                Error
              </button>
              <button class="btn btn-warning btn-sm" phx-click="trigger_warning">
                Warning
              </button>
            </div>

            <%!-- Toast containers with data-on-* attributes --%>
            <div class="mt-4 space-y-2">
              <div
                id="success-toast"
                class="alert alert-success hidden"
                data-on-action_success={JS.show(to: "#success-toast", transition: {"ease-out duration-300", "opacity-0 translate-y-2", "opacity-100 translate-y-0"}) |> JS.hide(to: "#success-toast", transition: {"ease-in duration-300", "opacity-100", "opacity-0"}, time: 2000)}
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span>Operation completed successfully!</span>
              </div>

              <div
                id="error-toast"
                class="alert alert-error hidden"
                data-on-action_error={JS.show(to: "#error-toast", transition: {"ease-out duration-300", "opacity-0 translate-y-2", "opacity-100 translate-y-0"}) |> JS.hide(to: "#error-toast", transition: {"ease-in duration-300", "opacity-100", "opacity-0"}, time: 2000)}
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span>Something went wrong!</span>
              </div>

              <div
                id="warning-toast"
                class="alert alert-warning hidden"
                data-on-action_warning={JS.show(to: "#warning-toast", transition: {"ease-out duration-300", "opacity-0 translate-y-2", "opacity-100 translate-y-0"}) |> JS.hide(to: "#warning-toast", transition: {"ease-in duration-300", "opacity-100", "opacity-0"}, time: 2000)}
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                </svg>
                <span>Proceed with caution!</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Section 2: Counter with Milestone --%>
        <div class="card bg-base-100 shadow-xl card-border border-secondary">
          <div class="card-body">
            <h2 class="card-title">Counter with Milestones</h2>
            <p class="text-sm text-base-content/70 mb-4">
              Every 5 increments triggers a <code>milestone_reached</code> event
              that shows a celebration animation.
            </p>

            <div class="text-center">
              <div class="stat">
                <div class="stat-value text-6xl">{@counter}</div>
                <div class="stat-desc">Current count</div>
              </div>

              <%!-- Milestone celebration overlay --%>
              <div
                id="milestone-celebration"
                class="hidden text-4xl animate-bounce"
                data-on-milestone_reached={JS.show(to: "#milestone-celebration") |> JS.hide(to: "#milestone-celebration", time: 1500)}
              >
                🎉 Milestone! 🎉
              </div>

              <%!-- Flash effect on counter change --%>
              <div
                id="counter-flash"
                class="hidden badge badge-primary badge-lg"
                data-on-counter_changed={JS.show(to: "#counter-flash", transition: {"ease-out duration-100", "opacity-0 scale-50", "opacity-100 scale-100"}) |> JS.hide(to: "#counter-flash", transition: {"ease-in duration-200", "opacity-100", "opacity-0"}, time: 300)}
              >
                +1
              </div>
            </div>

            <div class="flex gap-2 justify-center mt-4">
              <button class="btn btn-primary" phx-click="increment">
                Increment
              </button>
              <button class="btn btn-ghost" phx-click="reset">
                Reset
              </button>
            </div>
          </div>
        </div>

        <%!-- Section 3: Notification Badge --%>
        <div class="card bg-base-100 shadow-xl card-border border-accent">
          <div class="card-body">
            <h2 class="card-title">Notification Badge</h2>
            <p class="text-sm text-base-content/70 mb-4">
              The badge animates on each new notification using
              <code>data-on-new_notification</code>.
            </p>

            <div class="flex items-center justify-center gap-4">
              <div class="indicator">
                <span
                  id="notification-badge"
                  class={"indicator-item badge badge-secondary #{if @notification_count == 0, do: "hidden"}"}
                  data-on-new_notification={JS.remove_class("hidden", to: "#notification-badge") |> JS.transition({"animate-ping", "", ""}, to: "#notification-badge", time: 300)}
                  data-on-dismiss_notifications={JS.add_class("hidden", to: "#notification-badge")}
                >
                  {@notification_count}
                </span>
                <button class="btn btn-lg">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
                  </svg>
                  Inbox
                </button>
              </div>
            </div>

            <div class="flex gap-2 justify-center mt-4">
              <button class="btn btn-accent btn-sm" phx-click="trigger_notification">
                Add Notification
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="dismiss_all">
                Dismiss All
              </button>
            </div>
          </div>
        </div>

        <%!-- Section 4: Toggle Visibility --%>
        <div class="card bg-base-100 shadow-xl card-border border-info">
          <div class="card-body">
            <h2 class="card-title">Event-Driven Visibility</h2>
            <p class="text-sm text-base-content/70 mb-4">
              Elements respond to the same events in different ways.
              Reset hides all dynamic elements.
            </p>

            <div class="space-y-2">
              <div
                id="success-indicator"
                class="flex items-center gap-2 hidden"
                data-on-action_success={JS.show(to: "#success-indicator")}
                data-on-counter_reset={JS.hide(to: "#success-indicator")}
              >
                <div class="badge badge-success gap-1">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                  </svg>
                  Success triggered
                </div>
              </div>

              <div
                id="error-indicator"
                class="flex items-center gap-2 hidden"
                data-on-action_error={JS.show(to: "#error-indicator")}
                data-on-counter_reset={JS.hide(to: "#error-indicator")}
              >
                <div class="badge badge-error gap-1">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                  Error triggered
                </div>
              </div>

              <div
                id="warning-indicator"
                class="flex items-center gap-2 hidden"
                data-on-action_warning={JS.show(to: "#warning-indicator")}
                data-on-counter_reset={JS.hide(to: "#warning-indicator")}
              >
                <div class="badge badge-warning gap-1">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01" />
                  </svg>
                  Warning triggered
                </div>
              </div>

              <div
                id="counter-indicator"
                class="hidden"
                data-on-counter_changed={JS.show(to: "#counter-indicator")}
                data-on-counter_reset={JS.hide(to: "#counter-indicator")}
              >
                <div class="badge badge-info gap-1">
                  Counter was modified
                </div>
              </div>
            </div>

            <p class="text-xs text-base-content/50 mt-4">
              Click "Reset" in the Counter card to hide all indicators.
            </p>
          </div>
        </div>
      </div>

      <%!-- Code Example Section --%>
      <div class="card bg-base-200 shadow-xl mt-8">
        <div class="card-body">
          <h2 class="card-title">How It Works</h2>

          <div class="mockup-code text-sm">
            <pre data-prefix="1"><code>&lt;!-- Server pushes an event --&gt;</code></pre>
            <pre data-prefix="2"><code>{"push_event(socket, \"action_success\", %{message: \"Done!\"})"}</code></pre>
            <pre data-prefix="3"><code></code></pre>
            <pre data-prefix="4"><code>&lt;!-- Client element responds declaratively --&gt;</code></pre>
            <pre data-prefix="5"><code>&lt;div</code></pre>
            <pre data-prefix="6"><code>  class="alert hidden"</code></pre>
            <pre data-prefix="7"><code>{"  data-on-action_success={JS.show() |> JS.hide(time: 2000)}"}</code></pre>
            <pre data-prefix="8"><code>&gt;</code></pre>
            <pre data-prefix="9"><code>  Success!</code></pre>
            <pre data-prefix="10"><code>&lt;/div&gt;</code></pre>
          </div>

          <div class="mt-4 text-sm text-base-content/70">
            <p class="mb-2"><strong>Key benefits:</strong></p>
            <ul class="list-disc list-inside space-y-1">
              <li>No JavaScript hooks needed for simple show/hide/animate patterns</li>
              <li>Declarative - the behavior is defined right on the element</li>
              <li>Uses the full power of <code>Phoenix.LiveView.JS</code></li>
              <li>Multiple elements can respond to the same event differently</li>
              <li>Elements can respond to multiple events via multiple <code>data-on-*</code> attributes</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
