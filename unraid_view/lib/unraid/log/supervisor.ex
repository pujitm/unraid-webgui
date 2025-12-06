defmodule Unraid.Log.Supervisor do
  @moduledoc """
  Supervisor for the log subsystem.

  Manages:
  - `Unraid.Log.Registry` - Registry for LogMonitorServer process deduplication
  - `Unraid.Log.MonitorDynamicSupervisor` - DynamicSupervisor for LogMonitorServer processes
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Unraid.Log.Registry},
      {DynamicSupervisor, name: Unraid.Log.MonitorDynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
