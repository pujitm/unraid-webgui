defmodule UnraidWeb.DockerConsoleLive do
  @moduledoc """
  Dedicated fullscreen terminal for Docker container console.

  Accessed via /docker/:name/console

  Used for pop-out console windows from the Docker card view.
  """

  use UnraidWeb, :live_view

  alias Unraid.Docker
  alias Unraid.Terminal

  import UnraidWeb.TerminalComponents

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    socket =
      socket
      |> assign(:container_name, name)
      |> assign(:session_id, nil)
      |> assign(:inherited_session_id, nil)
      |> assign(:container, nil)
      |> assign(:error, nil)
      |> assign(:loading, true)

    {:ok, socket}
  end

  # Handle URL params to receive inherited session ID
  @impl true
  def handle_params(%{"session" => session_id}, _uri, socket) do
    socket = assign(socket, :inherited_session_id, session_id)

    if connected?(socket) do
      send(self(), {:init_console, socket.assigns.container_name})
    end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      send(self(), {:init_console, socket.assigns.container_name})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:init_console, name}, socket) do
    # Check if we have an inherited session to claim
    case socket.assigns.inherited_session_id do
      nil ->
        # No inherited session - create new one
        start_new_session(socket, name)

      inherited_id ->
        # Try to claim the inherited session
        claim_inherited_session(socket, name, inherited_id)
    end
  end

  # Claim an existing session that was handed off from the embedded console
  defp claim_inherited_session(socket, name, session_id) do
    require Logger
    container = find_container(name)

    Logger.info("[DockerConsoleLive] Claiming inherited session #{session_id}")

    # Subscribe to the existing session (this also adds us as a subscriber)
    Terminal.subscribe(session_id)

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:session_id, session_id)
     |> assign(:container, container)}
  end

  # Start a new terminal session for the container
  defp start_new_session(socket, name) do
    require Logger
    Logger.info("[DockerConsoleLive] Starting NEW session for #{name} (no inherited session)")

    case find_container(name) do
      nil ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, "Container not found: #{name}")}

      container ->
        if container.state != :running do
          {:noreply,
           socket
           |> assign(:loading, false)
           |> assign(:container, container)
           |> assign(:error, "Container is not running")}
        else
          shell = container.shell || "sh"

          case Terminal.start_docker_console(name, shell: shell, owner: self()) do
            {:ok, session_id} ->
              Terminal.subscribe(session_id)

              {:noreply,
               socket
               |> assign(:loading, false)
               |> assign(:session_id, session_id)
               |> assign(:container, container)}

            {:error, reason} ->
              {:noreply,
               socket
               |> assign(:loading, false)
               |> assign(:container, container)
               |> assign(:error, "Failed to start console: #{inspect(reason)}")}
          end
        end
    end
  end

  # Terminal output - forward to the terminal component
  @impl true
  def handle_info({:terminal_output, _session_id, data}, socket) do
    socket =
      push_event(socket, "terminal:output", %{
        id: "docker-console",
        data: Base.encode64(data)
      })

    {:noreply, socket}
  end

  # Terminal exit
  @impl true
  def handle_info({:terminal_exit, _session_id, exit_code}, socket) do
    socket =
      socket
      |> push_event("terminal:exit", %{id: "docker-console", code: exit_code})
      |> assign(:error, "Console exited with code #{exit_code}")

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Terminal events from JavaScript hook
  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    if socket.assigns.session_id do
      Terminal.send_input(socket.assigns.session_id, data)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    if socket.assigns.session_id do
      Terminal.resize(socket.assigns.session_id, cols, rows)
    end

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
    if socket.assigns.session_id do
      Terminal.unsubscribe(socket.assigns.session_id)
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
          <h1 class="text-lg font-semibold">
            Console: {@container_name}
          </h1>
          <span :if={@container} class="badge badge-sm badge-outline">
            {@container.shell || "sh"}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="reconnect"
            :if={@error && @container && @container.state == :running}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
          </button>
        </div>
      </div>

      <%!-- Loading State --%>
      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <%!-- Error State --%>
      <div :if={@error && !@session_id} class="flex-1 flex items-center justify-center">
        <div class="alert alert-error max-w-md">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error}</span>
        </div>
      </div>

      <%!-- Terminal --%>
      <div :if={@session_id} class="flex-1 p-2 min-h-0">
        <.terminal
          id="docker-console"
          session_id={@session_id}
          class="h-full rounded-lg overflow-hidden"
          theme="dark"
          font_size={14}
        />
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp find_container(name) do
    Docker.list_containers()
    |> Enum.find(&(&1.name == name))
  end
end
