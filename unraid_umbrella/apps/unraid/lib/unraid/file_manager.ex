defmodule Unraid.FileManager do
  alias Unraid.FileManager.Supervisor

  def read(file_path) do
    with {:ok, worker} <- Supervisor.get_or_start_worker(file_path) do
      GenServer.call(worker, {:read})
    end
  end

  def write(file_path, content) do
    with {:ok, worker} <- Supervisor.get_or_start_worker(file_path) do
      GenServer.call(worker, {:write, content})
    end
  end

  def append(file_path, content) do
    with {:ok, worker} <- Supervisor.get_or_start_worker(file_path) do
      GenServer.call(worker, {:append, content})
    end
  end

  def stop_worker(file_path) do
    Supervisor.stop_file_worker(file_path)
  end
end
