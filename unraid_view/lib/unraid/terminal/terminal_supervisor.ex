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
end
