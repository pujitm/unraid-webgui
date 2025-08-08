defmodule Unraid.FileManagerTest do
  use ExUnit.Case, async: true
  alias Unraid.FileManager

  setup do
    test_dir = Path.join(System.tmp_dir!(), "file_manager_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, test_dir: test_dir}
  end

  describe "FileManager" do
    test "writes and reads a file", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "test_file.txt")
      content = "Hello, FileManager!"

      assert :ok = FileManager.write(file_path, content)
      assert {:ok, ^content} = FileManager.read(file_path)
    end

    test "appends to a file", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "append_test.txt")

      assert :ok = FileManager.write(file_path, "Line 1\n")
      assert :ok = FileManager.append(file_path, "Line 2\n")
      assert :ok = FileManager.append(file_path, "Line 3\n")

      assert {:ok, "Line 1\nLine 2\nLine 3\n"} = FileManager.read(file_path)
    end

    test "handles concurrent operations on same file sequentially", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "concurrent_test.txt")
      num_operations = 100

      tasks =
        for i <- 1..num_operations do
          Task.async(fn ->
            FileManager.write(file_path, "Operation #{i}\n")
          end)
        end

      Enum.each(tasks, &Task.await/1)

      {:ok, final_content} = FileManager.read(file_path)
      assert String.contains?(final_content, "Operation")
    end

    test "handles operations on multiple files concurrently", %{test_dir: test_dir} do
      file_paths = for i <- 1..10, do: Path.join(test_dir, "file_#{i}.txt")

      tasks =
        for path <- file_paths do
          Task.async(fn ->
            FileManager.write(path, "Content for #{Path.basename(path)}")
            FileManager.read(path)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      Enum.each(results, fn {:ok, content} ->
        assert String.starts_with?(content, "Content for file_")
      end)
    end

    test "returns error when reading non-existent file", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "non_existent.txt")
      assert {:error, :enoent} = FileManager.read(file_path)
    end

    test "can stop a worker", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "worker_test.txt")

      assert :ok = FileManager.write(file_path, "Initial content")
      assert :ok = FileManager.stop_worker(file_path)

      # Worker should be restarted on next operation
      assert {:ok, "Initial content"} = FileManager.read(file_path)
    end

    test "handles large writes correctly", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "large_file.txt")
      large_content = String.duplicate("x", 1_000_000)

      assert :ok = FileManager.write(file_path, large_content)
      assert {:ok, ^large_content} = FileManager.read(file_path)
    end

    test "ensures sequential processing of operations", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "sequential_test.txt")

      # Start with empty file
      FileManager.write(file_path, "")

      # Launch multiple append operations
      operations = for i <- 1..50, do: {i, "Line #{i}\n"}

      tasks =
        for {_i, content} <- operations do
          Task.async(fn ->
            FileManager.append(file_path, content)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      {:ok, result} = FileManager.read(file_path)
      lines = String.split(result, "\n", trim: true)

      # All lines should be present
      assert length(lines) == 50
    end
  end
end
