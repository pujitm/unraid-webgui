defmodule Unraid.Log.LogMonitorServerTest do
  use ExUnit.Case, async: false
  use Unraid.TestHelpers

  alias Unraid.Log.LogMonitorServer

  @moduletag :tmp_dir

  # Fast poll interval for tests (20ms instead of default 500ms)
  @test_poll_interval 20
  # Timeout for waiting on poll-based updates (poll interval + buffer)
  @test_poll_wait 50

  setup %{tmp_dir: tmp_dir} do
    configure_fast_polling(:log_monitor_poll_interval, @test_poll_interval)
    %{tmp_dir: tmp_dir}
  end

  describe "subscribe/2" do
    test "returns initial lines in chronological order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "line one\nline two\nline three\n")

      {:ok, _pid, lines} = LogMonitorServer.subscribe(path, initial_lines: 10)

      assert length(lines) == 3

      # Lines should be chronological (oldest first)
      [line1, line2, line3] = lines
      assert line1.text == "line one"
      assert line2.text == "line two"
      assert line3.text == "line three"

      # Offsets should be byte positions
      assert line1.offset == 0
      assert line2.offset == 9
      assert line3.offset == 18
    end

    test "respects initial_lines limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")

      content =
        1..100
        |> Enum.map(fn i -> "line #{i}" end)
        |> Enum.join("\n")

      File.write!(path, content <> "\n")

      {:ok, _pid, lines} = LogMonitorServer.subscribe(path, initial_lines: 5)

      assert length(lines) == 5
      # Should be the 5 most recent (96-100) in chronological order
      texts = Enum.map(lines, & &1.text)
      assert texts == ["line 96", "line 97", "line 98", "line 99", "line 100"]
    end

    test "handles empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.log")
      File.write!(path, "")

      {:ok, _pid, lines} = LogMonitorServer.subscribe(path)

      assert lines == []
    end

    test "starts polling after subscribe", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "initial\n")

      {:ok, _pid, _lines} = LogMonitorServer.subscribe(path)

      # Append new content
      File.write!(path, "initial\nnew line\n")

      # Wait for poll
      assert_receive {:log_lines, ^path, new_lines}, @test_poll_wait

      assert length(new_lines) == 1
      assert hd(new_lines).text == "new line"
    end

    test "multiple subscribers receive same updates", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "initial\n")

      # Subscribe from this process
      {:ok, pid, _} = LogMonitorServer.subscribe(path)

      # Subscribe from another process
      test_pid = self()

      subscriber2 =
        spawn(fn ->
          {:ok, ^pid, _} = LogMonitorServer.subscribe(path)

          receive do
            msg -> send(test_pid, {:subscriber2, msg})
          end
        end)

      # Small delay to ensure second subscriber is registered
      Process.sleep(10)

      # Append new content
      File.write!(path, "initial\nnew line\n")

      # Both should receive the update
      assert_receive {:log_lines, ^path, _lines}, @test_poll_wait
      assert_receive {:subscriber2, {:log_lines, ^path, _lines}}, @test_poll_wait

      Process.exit(subscriber2, :kill)
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving updates after unsubscribe", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "initial\n")

      {:ok, _pid, _lines} = LogMonitorServer.subscribe(path)

      LogMonitorServer.unsubscribe(path)

      # Append new content
      File.write!(path, "initial\nnew line\n")

      # Should NOT receive the update
      refute_receive {:log_lines, ^path, _}, @test_poll_wait
    end
  end

  describe "load_history/3" do
    test "returns lines before given offset", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      # "line 1\n" = 7 bytes, so line 2 starts at 7, line 3 at 14, etc.
      File.write!(path, "line 1\nline 2\nline 3\nline 4\nline 5\n")

      # Load lines before offset 21 (where "line 4" starts)
      {lines, earliest} = LogMonitorServer.load_history(path, 21, 10)

      texts = Enum.map(lines, & &1.text)
      assert texts == ["line 1", "line 2", "line 3"]
      assert earliest == 0
    end

    test "respects count limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")

      content =
        1..20
        |> Enum.map(fn i -> "line #{i}" end)
        |> Enum.join("\n")

      File.write!(path, content <> "\n")

      # Get file size to use as before_offset
      {:ok, size} = Unraid.FileExtras.file_size(path)

      {lines, _earliest} = LogMonitorServer.load_history(path, size, 5)

      # Should get 5 lines, the most recent 5 before the offset
      assert length(lines) == 5
      texts = Enum.map(lines, & &1.text)
      assert texts == ["line 16", "line 17", "line 18", "line 19", "line 20"]
    end

    test "returns empty list when offset is 0", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "line 1\nline 2\n")

      {lines, earliest} = LogMonitorServer.load_history(path, 0, 10)

      assert lines == []
      assert earliest == 0
    end

    test "returns lines in chronological order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "first\nsecond\nthird\n")

      {:ok, size} = Unraid.FileExtras.file_size(path)
      {lines, _earliest} = LogMonitorServer.load_history(path, size, 10)

      texts = Enum.map(lines, & &1.text)
      assert texts == ["first", "second", "third"]
    end
  end

  describe "get_info/1" do
    test "returns monitor info when server exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "content\n")

      {:ok, _pid, _} = LogMonitorServer.subscribe(path)

      info = LogMonitorServer.get_info(path)

      assert info.path == Path.expand(path)
      assert info.subscriber_count == 1
      assert is_integer(info.offset)
      assert is_integer(info.file_size)
    end

    test "returns nil when no server exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.log")

      assert LogMonitorServer.get_info(path) == nil
    end
  end

  describe "file change detection" do
    test "detects appended content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "line 1\n")

      {:ok, _pid, _lines} = LogMonitorServer.subscribe(path)

      # Append multiple lines
      File.write!(path, "line 1\nline 2\nline 3\n")

      assert_receive {:log_lines, ^path, new_lines}, @test_poll_wait

      texts = Enum.map(new_lines, & &1.text)
      assert texts == ["line 2", "line 3"]
    end

    test "handles partial lines (no trailing newline yet)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "partial_test.log")
      File.write!(path, "line 1\n")

      {:ok, _pid, initial_lines} = LogMonitorServer.subscribe(path)

      # Verify we got initial line
      assert length(initial_lines) == 1
      assert hd(initial_lines).text == "line 1"

      # Drain any spurious messages from subscription setup
      receive do
        {:log_lines, ^path, _} -> :ok
      after
        @test_poll_wait -> :ok
      end

      # Append partial line (no newline)
      File.write!(path, "line 1\npartial", [:binary])

      # Wait for poll - should NOT receive partial line (no complete line yet)
      refute_receive {:log_lines, ^path, _}, @test_poll_wait

      # Now complete the line
      File.write!(path, "line 1\npartial complete\n")

      assert_receive {:log_lines, ^path, new_lines}, @test_poll_wait

      texts = Enum.map(new_lines, & &1.text)
      assert texts == ["partial complete"]
    end

    test "detects truncation and sends reset", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "line 1\nline 2\nline 3\n")

      {:ok, _pid, _lines} = LogMonitorServer.subscribe(path)

      # Truncate file
      File.write!(path, "new\n")

      assert_receive {:log_reset, ^path}, @test_poll_wait
    end

    test "correctly calculates line offsets for new data", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      # Initial: "abc\n" = 4 bytes
      File.write!(path, "abc\n")

      {:ok, _pid, _lines} = LogMonitorServer.subscribe(path)

      # Append: "defg\n" starts at offset 4
      File.write!(path, "abc\ndefg\n")

      assert_receive {:log_lines, ^path, [line]}, @test_poll_wait

      assert line.text == "defg"
      assert line.offset == 4
    end
  end

  describe "subscriber cleanup" do
    test "server stops when all subscribers exit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "content\n")

      test_pid = self()

      # Start subscriber in separate process
      subscriber =
        spawn(fn ->
          {:ok, pid, _} = LogMonitorServer.subscribe(path)
          send(test_pid, {:server_pid, pid})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:server_pid, server_pid}

      # Verify server is running
      assert Process.alive?(server_pid)

      # Kill subscriber and wait for server to stop
      send(subscriber, :exit)

      # Poll until server stops (faster than fixed sleep)
      assert poll_until(fn -> not Process.alive?(server_pid) end, 100),
             "Server should stop when all subscribers exit"
    end

    test "server continues with remaining subscribers", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "content\n")

      # Subscribe from this process
      {:ok, server_pid, _} = LogMonitorServer.subscribe(path)

      # Subscribe from another process
      test_pid = self()

      subscriber2 =
        spawn(fn ->
          {:ok, ^server_pid, _} = LogMonitorServer.subscribe(path)
          send(test_pid, :subscribed)

          receive do
            :exit -> :ok
          end
        end)

      assert_receive :subscribed

      # Kill second subscriber and wait briefly for cleanup
      send(subscriber2, :exit)
      Process.sleep(20)

      # Server should still be running
      assert Process.alive?(server_pid)

      # And we should still receive updates
      File.write!(path, "content\nnew line\n")
      assert_receive {:log_lines, ^path, _}, @test_poll_wait
    end
  end

  describe "registry and deduplication" do
    test "same path returns same server pid", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.log")
      File.write!(path, "content\n")

      {:ok, pid1, _} = LogMonitorServer.subscribe(path)
      {:ok, pid2, _} = LogMonitorServer.subscribe(path)

      assert pid1 == pid2
    end

    test "different paths return different servers", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "test1.log")
      path2 = Path.join(tmp_dir, "test2.log")
      File.write!(path1, "content1\n")
      File.write!(path2, "content2\n")

      {:ok, pid1, _} = LogMonitorServer.subscribe(path1)
      {:ok, pid2, _} = LogMonitorServer.subscribe(path2)

      assert pid1 != pid2
    end
  end
end
