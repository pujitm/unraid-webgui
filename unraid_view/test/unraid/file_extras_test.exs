defmodule Unraid.FileExtrasTest do
  use ExUnit.Case, async: true

  alias Unraid.FileExtras

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{tmp_dir: tmp_dir}
  end

  describe "file_size/1" do
    test "returns size of existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "hello")

      assert {:ok, 5} = FileExtras.file_size(path)
    end

    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.txt")

      assert {:error, :enoent} = FileExtras.file_size(path)
    end

    test "returns 0 for empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.txt")
      File.write!(path, "")

      assert {:ok, 0} = FileExtras.file_size(path)
    end
  end

  describe "read_from/2" do
    test "reads from offset to end of file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "hello world")

      assert {:ok, "world"} = FileExtras.read_from(path, 6)
    end

    test "reads entire file when offset is 0", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "hello world")

      assert {:ok, "hello world"} = FileExtras.read_from(path, 0)
    end

    test "returns empty binary when offset equals file size", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "hello")

      assert {:ok, <<>>} = FileExtras.read_from(path, 5)
    end

    test "returns empty binary when offset exceeds file size", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "hello")

      assert {:ok, <<>>} = FileExtras.read_from(path, 100)
    end

    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.txt")

      assert {:error, :enoent} = FileExtras.read_from(path, 0)
    end
  end

  describe "stream_reverse/2" do
    test "yields lines in reverse order (newest first)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line one\nline two\nline three\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert length(lines) == 3

      # Lines should be newest first
      [{offset3, text3}, {offset2, text2}, {offset1, text1}] = lines
      assert text3 == "line three"
      assert text2 == "line two"
      assert text1 == "line one"

      # Offsets should be correct byte positions
      assert offset1 == 0
      assert offset2 == 9
      assert offset3 == 18
    end

    test "handles file without trailing newline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line one\nline two\nline three")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert length(lines) == 3
      [{_offset3, text3}, {_offset2, text2}, {_offset1, text1}] = lines
      assert text3 == "line three"
      assert text2 == "line two"
      assert text1 == "line one"
    end

    test "handles empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.txt")
      File.write!(path, "")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert lines == []
    end

    test "handles single line without newline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "single.txt")
      File.write!(path, "only line")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert lines == [{0, "only line"}]
    end

    test "handles single line with newline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "single.txt")
      File.write!(path, "only line\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert lines == [{0, "only line"}]
    end

    test "filters out empty trailing line from trailing newline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line one\nline two\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      # Should only have 2 lines, not 3 (no empty line from trailing \n)
      assert length(lines) == 2
      texts = Enum.map(lines, fn {_offset, text} -> text end)
      refute "" in texts
    end

    test "preserves intentional empty lines in middle of file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line one\n\nline three\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert length(lines) == 3
      texts = Enum.map(lines, fn {_offset, text} -> text end)
      assert texts == ["line three", "", "line one"]
    end

    test "handles large file spanning multiple chunks", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large.txt")

      # Create file larger than default chunk size (8KB)
      lines_content =
        1..500
        |> Enum.map(fn i -> "This is log line number #{i} with padding to make it longer" end)
        |> Enum.join("\n")

      File.write!(path, lines_content <> "\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      assert length(lines) == 500

      # First yielded should be line 500 (newest)
      {_offset, first_text} = hd(lines)
      assert first_text =~ "line number 500"

      # Last yielded should be line 1 (oldest)
      {_offset, last_text} = List.last(lines)
      assert last_text =~ "line number 1"
    end

    test "take/2 limits results efficiently", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")

      lines_content =
        1..100
        |> Enum.map(fn i -> "line #{i}" end)
        |> Enum.join("\n")

      File.write!(path, lines_content <> "\n")

      # Take only 5 most recent lines
      recent =
        path
        |> FileExtras.stream_reverse()
        |> Enum.take(5)

      assert length(recent) == 5

      texts = Enum.map(recent, fn {_offset, text} -> text end)
      assert texts == ["line 100", "line 99", "line 98", "line 97", "line 96"]
    end

    test "reversing yields chronological order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "first\nsecond\nthird\n")

      # Common pattern: take N newest, then reverse for chronological
      chronological =
        path
        |> FileExtras.stream_reverse()
        |> Enum.take(3)
        |> Enum.reverse()

      texts = Enum.map(chronological, fn {_offset, text} -> text end)
      assert texts == ["first", "second", "third"]
    end

    test "handles Windows-style line endings (CRLF)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "line one\r\nline two\r\nline three\r\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      texts = Enum.map(lines, fn {_offset, text} -> text end)
      # \r should be trimmed
      assert texts == ["line three", "line two", "line one"]
    end

    test "byte offsets are accurate for each line", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      # "abc\n" = 4 bytes, "defgh\n" = 6 bytes, "ijklmnop\n" = 9 bytes
      File.write!(path, "abc\ndefgh\nijklmnop\n")

      lines =
        path
        |> FileExtras.stream_reverse()
        |> Enum.to_list()

      offsets = Enum.map(lines, fn {offset, _text} -> offset end)
      # ijklmnop starts at 10, defgh starts at 4, abc starts at 0
      assert offsets == [10, 4, 0]
    end
  end

  describe "stream_reverse_bytes/3" do
    test "yields chunks in reverse order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "0123456789")

      # Use small chunk size for testing
      chunks =
        path
        |> FileExtras.stream_reverse_bytes(:eof, 3)
        |> Enum.to_list()

      # 10 bytes with chunk_size 3: chunks at positions 9,6,3,0
      # Actually: 7-9 (3 bytes), 4-6 (3 bytes), 1-3 (3 bytes), 0 (1 byte)
      assert length(chunks) == 4

      [{offset1, data1} | _rest] = chunks
      # First chunk should be the last 3 bytes
      assert offset1 == 7
      assert data1 == "789"
    end

    test "handles file smaller than chunk size", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "small.txt")
      File.write!(path, "tiny")

      chunks =
        path
        |> FileExtras.stream_reverse_bytes(:eof, 8192)
        |> Enum.to_list()

      assert chunks == [{0, "tiny"}]
    end

    test "handles empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.txt")
      File.write!(path, "")

      chunks =
        path
        |> FileExtras.stream_reverse_bytes()
        |> Enum.to_list()

      assert chunks == []
    end
  end
end
