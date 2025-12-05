defmodule Unraid.Terminal do
  @moduledoc """
  Context module for terminal operations.

  Provides a high-level API for starting different types of terminal sessions
  and managing their lifecycle.

  ## Usage

      # Start a general shell
      {:ok, session_id} = Terminal.start_shell(owner: self())

      # Start a Docker container console
      {:ok, session_id} = Terminal.start_docker_console("container_id", shell: "bash")

      # Start an IEx REPL
      {:ok, session_id} = Terminal.start_iex()

      # Subscribe to session output
      Terminal.subscribe(session_id)

      # Send input
      Terminal.send_input(session_id, "ls -la\\n")

      # Resize
      Terminal.resize(session_id, 120, 40)

      # Close
      Terminal.close(session_id)
  """

  alias Phoenix.PubSub
  alias Unraid.Terminal.{TerminalSession, TerminalSupervisor}

  @doc """
  Starts a general shell session.

  ## Options

    * `:owner` - The PID to monitor. Session closes when owner dies. Defaults to caller.
    * `:cols` - Terminal columns. Defaults to 80.
    * `:rows` - Terminal rows. Defaults to 24.
    * `:shell` - Shell to use. Defaults to system SHELL or /bin/sh.
  """
  def start_shell(opts \\ []) do
    shell = opts[:shell] || System.get_env("SHELL") || "/bin/sh"
    start_session(shell, [], opts)
  end

  @doc """
  Starts a Docker container console session.

  Uses `docker exec -it <container_id> <shell>` to attach to the container.

  ## Options

    * `:owner` - The PID to monitor. Defaults to caller.
    * `:cols` - Terminal columns. Defaults to 80.
    * `:rows` - Terminal rows. Defaults to 24.
    * `:shell` - Shell to use inside container. Defaults to "sh".
  """
  def start_docker_console(container_id, opts \\ []) do
    shell = opts[:shell] || "sh"

    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        args = ["exec", "-it", container_id, shell]
        start_session(docker_path, args, opts)
    end
  end

  @doc """
  Starts an IEx REPL session connected to the current node.

  Note: This requires the node to be running in a distributed manner.

  ## Options

    * `:owner` - The PID to monitor. Defaults to caller.
    * `:cols` - Terminal columns. Defaults to 80.
    * `:rows` - Terminal rows. Defaults to 24.
  """
  def start_iex(opts \\ []) do
    case System.find_executable("iex") do
      nil ->
        {:error, :iex_not_found}

      iex_path ->
        # Connect to the current node if it's distributed
        args =
          if Node.alive?() do
            ["--remsh", to_string(Node.self())]
          else
            []
          end

        start_session(iex_path, args, opts)
    end
  end

  @doc """
  Starts a custom command session.

  ## Options

    * `:owner` - The PID to monitor. Defaults to caller.
    * `:cols` - Terminal columns. Defaults to 80.
    * `:rows` - Terminal rows. Defaults to 24.
  """
  def start_command(command, args \\ [], opts \\ []) do
    start_session(command, args, opts)
  end

  @doc """
  Sends input data to a terminal session.
  """
  def send_input(session_id, data) do
    TerminalSession.send_input(session_id, data)
  end

  @doc """
  Resizes a terminal session to the given dimensions.
  """
  def resize(session_id, cols, rows) do
    TerminalSession.resize(session_id, cols, rows)
  end

  @doc """
  Closes a terminal session.
  """
  def close(session_id) do
    TerminalSession.stop(session_id)
  end

  @doc """
  Subscribes to a terminal session's output.

  This also registers the calling process as a subscriber to the session,
  keeping the session alive as long as this process is subscribed.

  The subscriber will receive:
    * `{:terminal_output, session_id, data}` - Output from the PTY
    * `{:terminal_exit, session_id, exit_code}` - When the PTY exits
  """
  def subscribe(session_id) do
    # Register as session subscriber (keeps session alive)
    TerminalSession.add_subscriber(session_id, self())
    # Subscribe to PubSub for output
    PubSub.subscribe(Unraid.PubSub, topic(session_id))
  end

  @doc """
  Unsubscribes from a terminal session's output.

  This also deregisters the calling process from the session's subscriber list.
  If no subscribers remain, the session may be cleaned up after a timeout.
  """
  def unsubscribe(session_id) do
    # Deregister as session subscriber
    TerminalSession.remove_subscriber(session_id, self())
    # Unsubscribe from PubSub
    PubSub.unsubscribe(Unraid.PubSub, topic(session_id))
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp start_session(command, args, opts) do
    session_id = generate_session_id()

    session_opts = [
      id: session_id,
      command: command,
      args: args,
      owner: opts[:owner] || self(),
      cols: opts[:cols],
      rows: opts[:rows],
      permanent: opts[:permanent] || false
    ]

    case TerminalSupervisor.start_session(session_opts) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp topic(session_id) do
    "terminal:#{session_id}"
  end
end
