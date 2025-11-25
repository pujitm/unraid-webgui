defmodule UnraidViewWeb.TerminalLive do
  @moduledoc """
  Demo page for the terminal component.

  Demonstrates multiple independent terminal sessions with different use cases:
  - General shell access
  - Docker container console
  - IEx REPL
  """

  use UnraidViewWeb, :live_view

  alias UnraidView.Terminal

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        terminals: %{},
        next_terminal_num: 1,
        page_title: "Terminal"
      )

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up all terminal sessions when leaving the page
    Enum.each(socket.assigns.terminals, fn {_id, %{session_id: session_id}} ->
      Terminal.close(session_id)
    end)

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Terminal</h1>
        <div class="flex gap-2">
          <button
            phx-click="open_shell"
            class="btn btn-primary btn-sm"
          >
            New Shell
          </button>
          <button
            phx-click="open_iex"
            class="btn btn-secondary btn-sm"
          >
            IEx REPL
          </button>
        </div>
      </div>

      <div :if={map_size(@terminals) == 0} class="text-center py-12 text-base-content/60">
        <p>No terminals open. Click "New Shell" to start a terminal session.</p>
      </div>

      <div class="grid gap-4">
        <div
          :for={{terminal_id, terminal} <- @terminals}
          class="card bg-base-200 shadow"
        >
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-2">
              <h2 class="card-title text-sm">
                {terminal.label}
                <span class="badge badge-ghost badge-sm">{terminal_id}</span>
              </h2>
              <button
                phx-click="close_terminal"
                phx-value-id={terminal_id}
                class="btn btn-ghost btn-xs text-error"
              >
                Close
              </button>
            </div>
            <.terminal
              id={terminal_id}
              session_id={terminal.session_id}
              class="h-80"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_shell", _params, socket) do
    case Terminal.start_shell(owner: self()) do
      {:ok, session_id} ->
        Terminal.subscribe(session_id)

        terminal_id = "terminal-#{socket.assigns.next_terminal_num}"

        terminal = %{
          session_id: session_id,
          label: "Shell ##{socket.assigns.next_terminal_num}",
          type: :shell
        }

        socket =
          socket
          |> update(:terminals, &Map.put(&1, terminal_id, terminal))
          |> update(:next_terminal_num, &(&1 + 1))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start shell: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("open_iex", _params, socket) do
    case Terminal.start_iex(owner: self()) do
      {:ok, session_id} ->
        Terminal.subscribe(session_id)

        terminal_id = "terminal-#{socket.assigns.next_terminal_num}"

        terminal = %{
          session_id: session_id,
          label: "IEx REPL ##{socket.assigns.next_terminal_num}",
          type: :iex
        }

        socket =
          socket
          |> update(:terminals, &Map.put(&1, terminal_id, terminal))
          |> update(:next_terminal_num, &(&1 + 1))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start IEx: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("close_terminal", %{"id" => terminal_id}, socket) do
    case Map.get(socket.assigns.terminals, terminal_id) do
      nil ->
        {:noreply, socket}

      %{session_id: session_id} ->
        Terminal.unsubscribe(session_id)
        Terminal.close(session_id)

        socket = update(socket, :terminals, &Map.delete(&1, terminal_id))
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("terminal_input", %{"id" => terminal_id, "data" => data}, socket) do
    case get_session_id(socket, terminal_id) do
      nil -> {:noreply, socket}
      session_id ->
        Terminal.send_input(session_id, data)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("terminal_resize", %{"id" => terminal_id, "cols" => cols, "rows" => rows}, socket) do
    case get_session_id(socket, terminal_id) do
      nil -> {:noreply, socket}
      session_id ->
        Terminal.resize(session_id, cols, rows)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("terminal_ready", %{"id" => _terminal_id}, socket) do
    # Terminal is ready to receive output
    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_close", %{"id" => terminal_id}, socket) do
    # User pressed key after process exited, close the terminal
    handle_event("close_terminal", %{"id" => terminal_id}, socket)
  end

  # ---------------------------------------------------------------------------
  # PubSub Message Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:terminal_output, session_id, data}, socket) do
    case find_terminal_by_session(socket, session_id) do
      nil ->
        {:noreply, socket}

      terminal_id ->
        socket =
          push_event(socket, "terminal:output", %{
            id: terminal_id,
            data: Base.encode64(data)
          })

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:terminal_exit, session_id, exit_code}, socket) do
    case find_terminal_by_session(socket, session_id) do
      nil ->
        {:noreply, socket}

      terminal_id ->
        socket =
          push_event(socket, "terminal:exit", %{
            id: terminal_id,
            code: exit_code
          })

        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp get_session_id(socket, terminal_id) do
    case Map.get(socket.assigns.terminals, terminal_id) do
      nil -> nil
      %{session_id: session_id} -> session_id
    end
  end

  defp find_terminal_by_session(socket, session_id) do
    Enum.find_value(socket.assigns.terminals, fn {terminal_id, terminal} ->
      if terminal.session_id == session_id, do: terminal_id
    end)
  end
end
