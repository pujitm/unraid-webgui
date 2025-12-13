defmodule UnraidWeb.TerminalSessionLive do
  @moduledoc """
  Fullscreen terminal view for an existing session.

  Used for popout windows - claims an existing terminal session by its ID.
  The session must already exist (typically created by EmbeddedTerminalLive).

  Accessed via `/terminal/sessions/:session_id`
  """

  use UnraidWeb, :live_view

  alias Unraid.Terminal

  import UnraidWeb.TerminalComponents

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:error, nil)
      |> assign(:page_title, "Terminal")

    if connected?(socket) do
      send(self(), :claim_session)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:claim_session, socket) do
    session_id = socket.assigns.session_id

    # Subscribe to the existing session
    # This will add us as a subscriber, keeping the session alive
    Terminal.subscribe(session_id)

    {:noreply, socket}
  end

  # Terminal output - forward to the terminal component
  @impl true
  def handle_info({:terminal_output, _session_id, data}, socket) do
    socket =
      push_event(socket, "terminal:output", %{
        id: "terminal",
        data: Base.encode64(data)
      })

    {:noreply, socket}
  end

  # Terminal exit
  @impl true
  def handle_info({:terminal_exit, _session_id, exit_code}, socket) do
    socket =
      socket
      |> push_event("terminal:exit", %{id: "terminal", code: exit_code})
      |> assign(:error, "Session ended (exit code: #{exit_code})")

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Terminal events from JavaScript hook
  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    Terminal.send_input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    Terminal.resize(socket.assigns.session_id, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_ready", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_close", _params, socket) do
    # Close the window
    {:noreply, push_event(socket, "close-window", %{})}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:session_id] do
      Terminal.unsubscribe(socket.assigns.session_id)
      # Comment the line below to keep the session alive for reconnection, cleanup, or auditing purposes
      Terminal.close(socket.assigns.session_id)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-200">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-2 bg-base-300 border-b border-base-content/10">
        <div class="flex items-center gap-3">
          <.icon name="hero-command-line" class="w-5 h-5" />
          <h1 class="text-lg font-semibold">Terminal</h1>
          <span class="badge badge-sm badge-outline font-mono">
            {String.slice(@session_id, 0, 8)}...
          </span>
        </div>
      </div>

      <%!-- Error State --%>
      <div :if={@error} class="flex-1 flex items-center justify-center">
        <div class="alert alert-error max-w-md">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error}</span>
        </div>
      </div>

      <%!-- Terminal --%>
      <div :if={!@error} class="flex-1 p-2 min-h-0">
        <.terminal
          id="terminal"
          session_id={@session_id}
          class="h-full rounded-lg overflow-hidden"
          theme="dark"
          font_size={14}
        />
      </div>
    </div>
    """
  end
end
