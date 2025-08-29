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
    result = write_atomic(state.file_path, content, :write)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:append, content}, _from, state) do
    result = write_atomic(state.file_path, content, :append)
    {:reply, result, state}
  end

  defp write_atomic(file_path, content, mode) do
    # Ensure target directory exists
    dir = Path.dirname(file_path)
    with :ok <- File.mkdir_p(dir) do
      base = Path.basename(file_path)
      random_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      temp_path = Path.join(dir, ".#{base}.tmp.#{random_suffix}")

      with {:ok, final_content} <- prepare_content(file_path, content, mode),
           :ok <- File.write(temp_path, final_content),
           :ok <- File.rename(temp_path, file_path) do
        :ok
      else
        error ->
          File.rm(temp_path)
          error
      end
    end
  end

  defp prepare_content(_file_path, content, :write), do: {:ok, content}

  defp prepare_content(file_path, content, :append) do
    case File.read(file_path) do
      {:ok, existing_content} -> {:ok, existing_content <> content}
      {:error, :enoent} -> {:ok, content}  # File doesn't exist, just use new content
      error -> error
    end
  end
end
