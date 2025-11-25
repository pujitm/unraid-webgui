defmodule UnraidViewWeb.TerminalComponents do
  @moduledoc """
  Reusable terminal component for embedding in LiveViews.

  ## Usage

      <.terminal
        id="my-terminal"
        session_id={@terminal_session_id}
        class="h-96"
      />

  ## Required Event Handlers

  The parent LiveView must handle the following events:

  ### From JavaScript Hook

      def handle_event("terminal_input", %{"id" => id, "data" => data}, socket)
      def handle_event("terminal_resize", %{"id" => id, "cols" => c, "rows" => r}, socket)
      def handle_event("terminal_ready", %{"id" => id}, socket)
      def handle_event("terminal_close", %{"id" => id}, socket)

  ### From PubSub (via Terminal.subscribe/1)

      def handle_info({:terminal_output, session_id, data}, socket)
      def handle_info({:terminal_exit, session_id, code}, socket)

  ## Example Integration

      defmodule MyAppWeb.TerminalLive do
        use MyAppWeb, :live_view
        alias MyApp.Terminal

        def mount(_params, _session, socket) do
          {:ok, session_id} = Terminal.start_shell(owner: self())
          Terminal.subscribe(session_id)

          {:ok, assign(socket, session_id: session_id)}
        end

        def terminate(_reason, socket) do
          Terminal.close(socket.assigns.session_id)
        end

        def handle_event("terminal_input", %{"id" => _id, "data" => data}, socket) do
          Terminal.send_input(socket.assigns.session_id, data)
          {:noreply, socket}
        end

        def handle_event("terminal_resize", %{"id" => _id, "cols" => cols, "rows" => rows}, socket) do
          Terminal.resize(socket.assigns.session_id, cols, rows)
          {:noreply, socket}
        end

        def handle_info({:terminal_output, _session_id, data}, socket) do
          socket = push_event(socket, "terminal:output", %{
            id: "terminal",
            data: Base.encode64(data)
          })
          {:noreply, socket}
        end

        def handle_info({:terminal_exit, _session_id, code}, socket) do
          socket = push_event(socket, "terminal:exit", %{id: "terminal", code: code})
          {:noreply, socket}
        end

        def render(assigns) do
          ~H\"\"\"
          <.terminal id="terminal" session_id={@session_id} class="h-96" />
          \"\"\"
        end
      end
  """

  use Phoenix.Component

  @doc """
  Renders a terminal component.

  ## Attributes

    * `id` - Required. Unique DOM ID for the terminal element.
    * `session_id` - Required. Backend session ID from Terminal.start_*/1.
    * `class` - Optional. Additional CSS classes for the container.
    * `theme` - Optional. Terminal theme, "dark" or "light". Defaults to "dark".
    * `font_size` - Optional. Font size in pixels. Defaults to 14.

  ## Examples

      <.terminal id="shell" session_id={@session_id} />

      <.terminal
        id="docker-console"
        session_id={@docker_session}
        class="h-[500px] w-full"
        theme="light"
        font_size={12}
      />
  """
  attr :id, :string, required: true, doc: "Unique DOM ID for the terminal"
  attr :session_id, :string, required: true, doc: "Backend session ID"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :theme, :string, default: "dark", values: ~w(dark light), doc: "Terminal color theme"
  attr :font_size, :integer, default: 14, doc: "Font size in pixels"
  attr :rest, :global

  def terminal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["terminal-container", @class]}
      phx-hook="Terminal"
      phx-update="ignore"
      data-session-id={@session_id}
      data-theme={@theme}
      data-font-size={@font_size}
      {@rest}
    >
      <div data-terminal-target="container"></div>
    </div>
    """
  end
end
