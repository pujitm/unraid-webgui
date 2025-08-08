defmodule Unraid.FileManager.Supervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_file_worker(file_path) do
    spec = {Unraid.FileManager.FileWorker, file_path}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_file_worker(file_path) do
    case Registry.lookup(Unraid.FileManager.Registry, file_path) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  def get_file_worker(file_path) do
    case Registry.lookup(Unraid.FileManager.Registry, file_path) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def get_or_start_worker(file_path) do
    case get_file_worker(file_path) do
      {:ok, worker} ->
        if Process.alive?(worker) do
          {:ok, worker}
        else
          start_file_worker(file_path)
        end

      :error ->
        start_file_worker(file_path)
    end
  end
end
