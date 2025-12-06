defmodule Unraid.FileExtras do
  @moduledoc """
  Utility functions for efficient file operations, particularly
  reverse reading for log tailing.
  """

  @default_chunk_size 8192

  @doc """
  Creates a Stream that yields lines in reverse order (newest first).

  ## Parameters
  - `path` - File path to read
  - `from` - Starting position: `:eof` (default) or byte offset

  ## Returns
  Stream of `{byte_offset, line_text}` tuples where byte_offset is
  the position where the line starts in the file.

  ## Example

      FileExtras.stream_reverse("/var/log/syslog")
      |> Enum.take(100)
      |> Enum.reverse()  # Get oldest-first order
  """
  @spec stream_reverse(Path.t(), :eof | non_neg_integer()) :: Enumerable.t()
  def stream_reverse(path, from \\ :eof) do
    Stream.resource(
      fn -> init_reverse_state(path, from) end,
      &next_reverse_line/1,
      &cleanup_reverse_state/1
    )
  end

  @doc """
  Creates a Stream that yields byte chunks in reverse order.

  ## Parameters
  - `path` - File path to read
  - `from` - Starting position: `:eof` (default) or byte offset
  - `chunk_size` - Size of chunks to read (default: 8192)

  ## Returns
  Stream of `{start_offset, binary}` tuples.
  """
  @spec stream_reverse_bytes(Path.t(), :eof | non_neg_integer(), pos_integer()) :: Enumerable.t()
  def stream_reverse_bytes(path, from \\ :eof, chunk_size \\ @default_chunk_size) do
    Stream.resource(
      fn -> init_chunk_state(path, from, chunk_size) end,
      &next_chunk/1,
      &cleanup_chunk_state/1
    )
  end

  @doc """
  Reads file content from a byte offset to EOF.

  ## Returns
  - `{:ok, binary}` - Content from offset to EOF
  - `{:error, reason}` - File error
  """
  @spec read_from(Path.t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def read_from(path, offset) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          case File.stat(path) do
            {:ok, %File.Stat{size: size}} when size > offset ->
              case :file.pread(io, offset, size - offset) do
                {:ok, data} -> {:ok, data}
                :eof -> {:ok, <<>>}
                {:error, reason} -> {:error, reason}
              end

            {:ok, _} ->
              {:ok, <<>>}

            {:error, reason} ->
              {:error, reason}
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the current size of a file.

  ## Returns
  - `{:ok, size}` - File size in bytes
  - `{:error, reason}` - File error
  """
  @spec file_size(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # stream_reverse implementation
  # ============================================================================

  defp init_reverse_state(path, from) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        position =
          case from do
            :eof ->
              case File.stat(path) do
                {:ok, %File.Stat{size: size}} -> size
                _ -> 0
              end

            offset when is_integer(offset) ->
              offset
          end

        # State: {io_device, current_position, pending_lines, leftover_bytes}
        # pending_lines: lines parsed but not yet yielded (in reverse order, newest first)
        # leftover_bytes: partial line at the beginning of a chunk (needs previous chunk)
        {:ok, io, position, [], <<>>}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_reverse_line({:error, _reason} = state), do: {:halt, state}

  defp next_reverse_line({:ok, io, position, [], leftover}) when position <= 0 do
    # No more chunks to read
    if leftover != <<>> do
      # The leftover is the first line of the file (no newline before it)
      # Trim trailing \r for Windows-style line endings
      line = String.trim_trailing(leftover, "\r")
      {[{0, line}], {:ok, io, 0, [], <<>>}}
    else
      {:halt, {:ok, io, 0, [], <<>>}}
    end
  end

  defp next_reverse_line({:ok, io, position, [], leftover}) do
    # Need to read another chunk
    chunk_size = min(position, @default_chunk_size)
    read_start = position - chunk_size

    case :file.pread(io, read_start, chunk_size) do
      {:ok, chunk} ->
        # Combine chunk with leftover (leftover goes at end since it's continuation)
        combined = chunk <> leftover
        {lines, new_leftover} = parse_lines_reverse(combined, read_start)

        case lines do
          [] ->
            # No complete lines yet, continue reading
            next_reverse_line({:ok, io, read_start, [], new_leftover})

          _ ->
            # Return first line, keep rest as pending
            [first | rest] = lines
            {[first], {:ok, io, read_start, rest, new_leftover}}
        end

      :eof ->
        {:halt, {:ok, io, 0, [], leftover}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp next_reverse_line({:ok, io, position, [line | rest], leftover}) do
    # Have pending lines to yield
    {[line], {:ok, io, position, rest, leftover}}
  end

  defp cleanup_reverse_state({:ok, io, _, _, _}), do: File.close(io)
  defp cleanup_reverse_state({:error, _}), do: :ok

  # Parse chunk into lines, returning {lines_with_offsets, leftover}
  # Lines are returned newest-first (reverse order)
  defp parse_lines_reverse(chunk, base_offset) do
    # Split by newline
    parts = :binary.split(chunk, <<"\n">>, [:global])

    case parts do
      [single] ->
        # No newline in chunk - entire thing is leftover
        {[], single}

      [first | rest] ->
        # First part is leftover (beginning of a line from previous chunk)
        # Rest are complete lines (except possibly the last which ends with newline)
        lines_reversed = build_lines_with_offsets(rest, base_offset + byte_size(first) + 1, [])
        {lines_reversed, first}
    end
  end

  # Build list of {offset, line} tuples
  # offset is where each line starts in the file
  # Filters out empty strings (from trailing newlines)
  defp build_lines_with_offsets([], _offset, acc), do: acc

  defp build_lines_with_offsets([part | rest], offset, acc) do
    line = String.trim_trailing(part, "\r")
    new_offset = offset + byte_size(part) + 1

    # Skip empty lines that result from trailing newlines at EOF
    new_acc =
      if line == "" and rest == [] do
        acc
      else
        [{offset, line} | acc]
      end

    build_lines_with_offsets(rest, new_offset, new_acc)
  end

  # ============================================================================
  # stream_reverse_bytes implementation
  # ============================================================================

  defp init_chunk_state(path, from, chunk_size) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        position =
          case from do
            :eof ->
              case File.stat(path) do
                {:ok, %File.Stat{size: size}} -> size
                _ -> 0
              end

            offset when is_integer(offset) ->
              offset
          end

        {:ok, io, position, chunk_size}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_chunk({:error, _} = state), do: {:halt, state}

  defp next_chunk({:ok, _io, position, _chunk_size}) when position <= 0 do
    {:halt, {:ok, nil, 0, 0}}
  end

  defp next_chunk({:ok, io, position, chunk_size}) do
    read_size = min(position, chunk_size)
    read_start = position - read_size

    case :file.pread(io, read_start, read_size) do
      {:ok, data} ->
        {[{read_start, data}], {:ok, io, read_start, chunk_size}}

      :eof ->
        {:halt, {:ok, io, 0, chunk_size}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp cleanup_chunk_state({:ok, io, _, _}) when is_pid(io), do: File.close(io)
  defp cleanup_chunk_state({:ok, nil, _, _}), do: :ok
  defp cleanup_chunk_state({:error, _}), do: :ok
end
