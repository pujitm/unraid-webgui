defmodule Unraid.Terminal.TerminalSupervisor do
  @moduledoc """
  DynamicSupervisor for terminal sessions.

  Each terminal session runs as a supervised child that will be
  automatically cleaned up when the session terminates.
  """

  use DynamicSupervisor

  alias Unraid.Terminal.TerminalSession

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new terminal session under supervision.
  """
  def start_session(opts) do
    DynamicSupervisor.start_child(__MODULE__, {TerminalSession, opts})
  end

  @doc """
  Lists all active session IDs.

  Used by SessionCleanup to enumerate sessions for orphan detection.
  """
  def list_sessions do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, :worker, _} when is_pid(pid) ->
        case Registry.keys(Unraid.Terminal.Registry, pid) do
          [session_id] -> [session_id]
          _ -> []
        end

      _ ->
        []
    end)
  end
end
