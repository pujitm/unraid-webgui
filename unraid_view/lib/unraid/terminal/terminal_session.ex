defmodule Unraid.Terminal.TerminalSession do
  @moduledoc """
  GenServer managing a single PTY session.

  Handles:
  - PTY process spawning via ExPTY
  - Input forwarding from LiveView to PTY
  - Output streaming from PTY to LiveView via PubSub
  - Terminal resize operations
  - Graceful shutdown when owner process dies
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub

  @default_cols 80
  @default_rows 24

  defstruct [:id, :pty, :owner_pid, :owner_ref, :command, :args, :cols, :rows, :started_at]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:id]))
  end

  @doc """
  Sends input data to the PTY.
  """
  def send_input(session_id, data) do
    GenServer.cast(via_tuple(session_id), {:input, data})
  end

  @doc """
  Resizes the PTY to the given dimensions.
  """
  def resize(session_id, cols, rows) do
    GenServer.cast(via_tuple(session_id), {:resize, cols, rows})
  end

  @doc """
  Stops the terminal session.
  """
  def stop(session_id) do
    GenServer.stop(via_tuple(session_id), :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Returns the via tuple for process registration.
  """
  def via_tuple(session_id) do
    {:via, Registry, {Unraid.Terminal.Registry, session_id}}
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trap exits to ensure terminate/2 is called for cleanup
    Process.flag(:trap_exit, true)

    owner_pid = opts[:owner] || self()
    owner_ref = Process.monitor(owner_pid)

    state = %__MODULE__{
      id: opts[:id],
      owner_pid: owner_pid,
      owner_ref: owner_ref,
      command: opts[:command],
      args: opts[:args] || [],
      cols: opts[:cols] || @default_cols,
      rows: opts[:rows] || @default_rows,
      started_at: DateTime.utc_now()
    }

    {:ok, state, {:continue, :spawn_pty}}
  end

  @impl true
  def handle_continue(:spawn_pty, state) do
    case spawn_pty(state) do
      {:ok, pty} ->
        Logger.debug("[TerminalSession] Started session #{state.id}")
        {:noreply, %{state | pty: pty}}

      {:error, reason} ->
        Logger.error("[TerminalSession] Failed to spawn PTY: #{inspect(reason)}")
        broadcast_exit(state.id, 1)
        {:stop, {:shutdown, reason}, state}
    end
  end

  @impl true
  def handle_cast({:input, data}, %{pty: pty} = state) when not is_nil(pty) do
    ExPTY.write(pty, data)
    {:noreply, state}
  end

  def handle_cast({:input, _data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, %{pty: pty} = state) when not is_nil(pty) do
    ExPTY.resize(pty, cols, rows)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  def handle_cast({:resize, cols, rows}, state) do
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:pty_data, data}, state) do
    broadcast_output(state.id, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exit, exit_code}, state) do
    Logger.debug("[TerminalSession] PTY exited with code #{exit_code}")
    broadcast_exit(state.id, exit_code)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    Logger.debug("[TerminalSession] Owner process died, shutting down session #{state.id}")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:EXIT, pty, reason}, %{pty: pty} = state) do
    Logger.debug("[TerminalSession] PTY process exited: #{inspect(reason)}")
    broadcast_exit(state.id, 0)
    {:stop, :normal, %{state | pty: nil}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Ignore other EXIT messages
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[TerminalSession] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{pty: pty}) when not is_nil(pty) do
    # SIGKILL = 9 (force kill to ensure cleanup)
    # Using SIGKILL instead of SIGTERM to ensure the process dies immediately
    try do
      ExPTY.kill(pty, 9)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp spawn_pty(state) do
    pid = self()

    # Wrap command to close inherited file descriptors (3-1024) before exec
    # This prevents the shell from holding onto the Phoenix server's listening socket
    {command, args} = wrap_command_to_close_fds(state.command, state.args)

    ExPTY.spawn(
      command,
      args,
      name: "xterm-256color",
      cols: state.cols,
      rows: state.rows,
      # on_data callback receives (module, pty_pid, data)
      on_data: fn _module, _pty_pid, data -> send(pid, {:pty_data, data}) end,
      # on_exit callback receives (module, pty_pid, exit_code, signal_code)
      on_exit: fn _module, _pty_pid, code, _signal -> send(pid, {:pty_exit, code}) end
    )
  end

  # Wrap the command in a shell that closes inherited file descriptors
  # This prevents child processes from inheriting the server's listening socket
  defp wrap_command_to_close_fds(command, args) do
    # Build the full command string
    full_command =
      if args == [] do
        command
      else
        Enum.join([command | args], " ")
      end

    # Use bash to close file descriptors 3-255 before executing the command
    # This is a common pattern to prevent fd leakage to child processes
    wrapper_script = """
    for fd in $(seq 3 255); do
      eval "exec $fd<&-" 2>/dev/null
    done
    exec #{full_command}
    """

    {"/bin/bash", ["-c", wrapper_script]}
  end

  defp broadcast_output(session_id, data) do
    PubSub.broadcast(Unraid.PubSub, topic(session_id), {:terminal_output, session_id, data})
  end

  defp broadcast_exit(session_id, exit_code) do
    PubSub.broadcast(Unraid.PubSub, topic(session_id), {:terminal_exit, session_id, exit_code})
  end

  defp topic(session_id) do
    "terminal:#{session_id}"
  end
end
