defmodule Unraid.FileManager.FileWorker do
  use GenServer

  def start_link(file_path) do
    GenServer.start_link(__MODULE__, file_path,
      name: {:via, Registry, {Unraid.FileManager.Registry, file_path}}
    )
  end

  @impl true
  def init(file_path) do
    {:ok, %{file_path: file_path}}
  end

  @impl true
  def handle_call({:read}, _from, state) do
    result = File.read(state.file_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:write, content}, _from, state) do
    result = File.write(state.file_path, content)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:append, content}, _from, state) do
    result = File.write(state.file_path, content, [:append])
    {:reply, result, state}
  end
end
