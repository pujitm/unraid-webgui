defmodule UnraidWeb.EmbeddedTerminalLive do
  @moduledoc """
  Embeddable terminal LiveView for use as a child in other LiveViews.

  This is a child LiveView that fully encapsulates terminal session management,
  receiving PubSub messages directly and handling all terminal events internally.

  ## Usage

      <%= live_render(@socket, UnraidWeb.EmbeddedTerminalLive,
        id: "console-mycontainer",
        session: %{
          "type" => "docker",
          "container" => "mycontainer",
          "shell" => "bash"
        }
      ) %>

  ## Session Options

    * `"type"` - Required. One of: `"docker"`, `"shell"`, `"iex"`
    * `"container"` - Required for docker type. Container name.
    * `"shell"` - Shell to use. Defaults to "sh" for docker, system SHELL for shell.
    * `"parent_pid"` - Optional. PID to notify of session events.
    * `"class"` - Optional. CSS classes for the terminal container.
    * `"theme"` - Optional. "dark" or "light". Defaults to "dark".
    * `"font_size"` - Optional. Font size in pixels. Defaults to 14.
    * `"show_popout_button"` - Optional. Show a popout button. Defaults to false.

  ## Parent Notifications

  If `parent_pid` is provided, the following messages are sent:

    * `{:terminal_started, id, session_id, pid}` - When session starts successfully
    * `{:terminal_closed, id}` - When the terminal is closed

  ## Triggering Popout from Parent

  Parents can trigger popout by sending a message to the child:

      send(child_pid, {:prepare_popout, session_id})

  The child will capture the buffer and open the popout window directly.
  """

  use UnraidWeb, :live_view

  alias Unraid.Terminal

  @impl true
  def mount(_params, session, socket) do
    # The socket.id contains the live_render id (e.g., "console-14f97cddad84")
    terminal_id = socket.id

    socket =
      socket
      |> assign(:terminal_id, terminal_id)
      |> assign(:type, parse_type(session["type"]))
      |> assign(:container, session["container"])
      |> assign(:shell, session["shell"])
      |> assign(:parent_pid, session["parent_pid"])
      |> assign(:class, session["class"] || "h-80")
      |> assign(:theme, session["theme"] || "dark")
      |> assign(:font_size, session["font_size"] || 14)
      |> assign(:show_popout_button, session["show_popout_button"] || false)
      |> assign(:session_id, nil)
      |> assign(:error, nil)
      |> assign(:handing_off, false)

    if connected?(socket) do
      send(self(), :start_session)
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    # Use terminal_id as the element ID to ensure uniqueness across multiple terminals
    assigns = assign(assigns, :element_id, "terminal-#{assigns.terminal_id}")

    ~H"""
    <div class={["relative", @class]}>
      <%!-- Popout button overlay --%>
      <div
        :if={@show_popout_button && @session_id}
        class="absolute top-2 right-2 z-10"
      >
        <button
          type="button"
          class="btn btn-ghost btn-xs bg-base-300/80 hover:bg-base-300"
          phx-click="popout"
          title="Pop out to new window"
        >
          <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
        </button>
      </div>

      <div
        :if={@session_id}
        id={@element_id}
        class="terminal-container h-full w-full"
        phx-hook="Terminal"
        phx-update="ignore"
        data-session-id={@session_id}
        data-theme={@theme}
        data-font-size={@font_size}
      >
        <div data-terminal-target="container"></div>
      </div>

      <div
        :if={!@session_id && !@error}
        class="absolute inset-0 flex items-center justify-center bg-base-300"
      >
        <span class="loading loading-spinner loading-md"></span>
      </div>

      <div
        :if={@error}
        class="absolute inset-0 flex items-center justify-center bg-base-300"
      >
        <div class="alert alert-error max-w-sm">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error}</span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Handle Info - Session Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:start_session, socket) do
    case start_terminal_session(socket.assigns) do
      {:ok, session_id} ->
        Terminal.subscribe(session_id)
        # Include self() so parent can send messages to us
        notify_parent(socket, {:terminal_started, socket.assigns.terminal_id, session_id, self()})
        {:noreply, assign(socket, session_id: session_id)}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  # Prepare for popout handoff - unsubscribe but don't close session
  def handle_info(:prepare_handoff, socket) do
    if socket.assigns.session_id do
      Terminal.unsubscribe(socket.assigns.session_id)
      notify_parent(socket, {:terminal_handoff_ready, socket.assigns.terminal_id, socket.assigns.session_id})
      {:noreply, assign(socket, session_id: nil, handing_off: true)}
    else
      {:noreply, socket}
    end
  end

  # Parent is requesting popout - start the popout flow
  def handle_info({:prepare_popout, session_id}, socket) do
    if socket.assigns.session_id == session_id do
      {:noreply, start_popout_flow(socket)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Handle Info - PubSub Messages (received DIRECTLY!)
  # ---------------------------------------------------------------------------

  def handle_info({:terminal_output, session_id, data}, socket) do
    if socket.assigns.session_id == session_id do
      socket =
        push_event(socket, "terminal:output", %{
          id: terminal_element_id(socket),
          data: Base.encode64(data)
        })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:terminal_exit, session_id, exit_code}, socket) do
    if socket.assigns.session_id == session_id do
      socket =
        socket
        |> push_event("terminal:exit", %{id: terminal_element_id(socket), code: exit_code})
        |> assign(:error, "Process exited with code #{exit_code}")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Handle Event - From JavaScript Hook
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    if socket.assigns.session_id do
      Terminal.send_input(socket.assigns.session_id, data)
    end

    {:noreply, socket}
  end

  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    if socket.assigns.session_id do
      Terminal.resize(socket.assigns.session_id, cols, rows)
    end

    {:noreply, socket}
  end

  def handle_event("terminal_ready", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("terminal_close", _params, socket) do
    {:noreply, stop_session(socket)}
  end

  # Handle buffer captured event for popout handoff
  def handle_event("terminal_buffer_captured", %{"session_id" => session_id}, socket) do
    if socket.assigns.session_id == session_id do
      # Unsubscribe but don't close - popout will claim the session
      Terminal.unsubscribe(socket.assigns.session_id)

      # Generate popout URL
      url = popout_url(socket)

      # Open the popout window
      socket =
        socket
        |> push_event("console:popout", %{url: url})
        |> assign(session_id: nil, handing_off: true)

      # Notify parent that we're done (they can clean up tracking)
      notify_parent(socket, {:terminal_closed, socket.assigns.terminal_id})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Popout button clicked
  def handle_event("popout", _params, socket) do
    if socket.assigns.session_id do
      {:noreply, start_popout_flow(socket)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Terminate - Cleanup
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(_reason, socket) do
    # Don't close if handing off to popout
    if socket.assigns[:session_id] && !socket.assigns[:handing_off] do
      Terminal.unsubscribe(socket.assigns.session_id)
      Terminal.close(socket.assigns.session_id)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp parse_type("docker"), do: :docker
  defp parse_type("shell"), do: :shell
  defp parse_type("iex"), do: :iex
  defp parse_type(type) when is_atom(type), do: type
  defp parse_type(_), do: :shell

  defp start_terminal_session(%{type: :docker, container: container, shell: shell}) do
    Terminal.start_docker_console(container, shell: shell || "sh", owner: self())
  end

  defp start_terminal_session(%{type: :shell, shell: shell}) do
    opts = if shell, do: [shell: shell, owner: self()], else: [owner: self()]
    Terminal.start_shell(opts)
  end

  defp start_terminal_session(%{type: :iex}) do
    Terminal.start_iex(owner: self())
  end

  defp stop_session(socket) do
    if socket.assigns.session_id do
      Terminal.unsubscribe(socket.assigns.session_id)
      Terminal.close(socket.assigns.session_id)
    end

    assign(socket, session_id: nil)
  end

  defp notify_parent(%{assigns: %{parent_pid: pid}}, msg) when is_pid(pid) do
    send(pid, msg)
  end

  defp notify_parent(_, _), do: :ok

  defp format_error(:docker_not_found), do: "Docker not found"
  defp format_error(:iex_not_found), do: "IEx not found"
  defp format_error(reason), do: inspect(reason)

  # Start the popout flow by capturing the terminal buffer
  defp start_popout_flow(socket) do
    push_event(socket, "terminal:capture_buffer", %{
      id: terminal_element_id(socket),
      session_id: socket.assigns.session_id
    })
  end

  # Generate the unique element ID for this terminal
  defp terminal_element_id(socket) do
    "terminal-#{socket.assigns.terminal_id}"
  end

  # Generate the popout URL
  defp popout_url(socket) do
    "/terminal/sessions/#{socket.assigns.session_id}"
  end
end
