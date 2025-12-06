defmodule UnraidWeb.EmbeddedLogMonitorLiveTest do
  use UnraidWeb.ConnCase, async: false
  use Unraid.TestHelpers
  use Unraid.TestHelpers.LiveView

  import Phoenix.LiveViewTest

  alias Unraid.Log.LogMonitorServer

  @moduletag :tmp_dir

  # Fast poll interval for tests (20ms instead of default 500ms)
  @test_poll_interval 20

  setup do
    configure_fast_polling(:log_monitor_poll_interval, @test_poll_interval)
    :ok
  end

  # Wait for subscription by polling until line count changes from 0
  # This is log-monitor-specific, so kept local to this test module
  defp wait_for_subscription(view, timeout \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_subscription(view, deadline)
  end

  defp do_wait_for_subscription(view, deadline) do
    html = render(view)

    cond do
      # Subscription complete - has lines (but not exactly "0 lines") or has error
      # Use word boundary to avoid "10 lines" matching "0 lines"
      html =~ ~r/\d+ lines/ and not (html =~ ~r/\b0 lines\b/) ->
        html

      html =~ "File not found" ->
        html

      # Timeout
      System.monotonic_time(:millisecond) > deadline ->
        html

      # Keep waiting
      true ->
        Process.sleep(5)
        do_wait_for_subscription(view, deadline)
    end
  end

  describe "mount" do
    test "displays initial lines from file", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mount_initial.log")
      File.write!(path, "line one\nline two\nline three\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      # Wait for async subscription
      rendered = wait_for_subscription(view)

      # Should display all three lines
      assert rendered =~ "line one"
      assert rendered =~ "line two"
      assert rendered =~ "line three"

      # Should show line count
      assert rendered =~ "3 lines"
    end

    test "displays error when file not found", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.log")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      rendered = wait_for_subscription(view)
      assert rendered =~ "File not found"
    end

    test "uses custom label when provided", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "custom_label.log")
      File.write!(path, "content\n")

      {:ok, _view, html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "label" => "My Custom Log"}
        )

      # Label is set synchronously in mount, doesn't need wait
      assert html =~ "My Custom Log"
    end

    test "defaults label to filename", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "syslog.log")
      File.write!(path, "content\n")

      {:ok, _view, html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      # Label is set synchronously in mount
      assert html =~ "syslog.log"
    end

    test "respects initial_lines option", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "initial_lines.log")

      content =
        1..20
        |> Enum.map(fn i -> "line #{i}" end)
        |> Enum.join("\n")

      File.write!(path, content <> "\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "initial_lines" => 5}
        )

      rendered = wait_for_subscription(view)

      # Should show only 5 lines (16-20)
      assert rendered =~ "5 lines"
      assert rendered =~ "line 20"
      assert rendered =~ "line 16"
      refute rendered =~ "line 15"
    end

    test "notifies parent_pid when started", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "notify_parent.log")
      File.write!(path, "content\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "parent_pid" => self()}
        )

      wait_for_subscription(view)

      # Should receive notification
      expanded_path = Path.expand(path)
      assert_receive {:log_monitor_started, _id, ^expanded_path, _pid}, 1000
    end
  end

  describe "real-time updates" do
    test "displays new lines when file is appended", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "realtime_append.log")
      File.write!(path, "initial line\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Append new content
      File.write!(path, "initial line\nnew line\n")

      # Wait for update
      rendered = wait_for_content(view, "2 lines")
      assert rendered =~ "new line"
    end

    test "handles multiple new lines at once", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "realtime_multi.log")
      File.write!(path, "line 1\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Append multiple lines
      File.write!(path, "line 1\nline 2\nline 3\nline 4\n")

      rendered = wait_for_content(view, "4 lines")
      assert rendered =~ "line 2"
      assert rendered =~ "line 3"
      assert rendered =~ "line 4"
    end

    test "resets on file truncation", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "realtime_truncate.log")
      File.write!(path, "line 1\nline 2\nline 3\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "parent_pid" => self()}
        )

      wait_for_subscription(view)

      # Initial state
      assert render(view) =~ "3 lines"

      # Truncate file
      File.write!(path, "truncated\n")

      # Should receive reset notification
      expanded_path = Path.expand(path)
      assert_receive {:log_monitor_reset, _id, ^expanded_path}, 200

      rendered = wait_for_content(view, "0 lines")
      assert rendered =~ "0 lines"
    end
  end

  describe "toggle_auto_scroll event" do
    test "toggles auto_scroll state", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "toggle_auto.log")
      File.write!(path, "content\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Initially auto-scroll should be enabled
      rendered = render(view)
      assert rendered =~ "Auto-scroll"
      assert rendered =~ ~s(data-auto-scroll="true")

      # Toggle off
      view |> element("input[type=checkbox]") |> render_click()

      rendered = render(view)
      assert rendered =~ ~s(data-auto-scroll="false")
    end

    test "accepts explicit boolean value from JS hook", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "toggle_explicit.log")
      File.write!(path, "content\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Simulate JS hook sending explicit false
      render_click(view, "toggle_auto_scroll", %{"value" => false})

      rendered = render(view)
      assert rendered =~ ~s(data-auto-scroll="false")

      # Simulate JS hook sending explicit true
      render_click(view, "toggle_auto_scroll", %{"value" => true})

      rendered = render(view)
      assert rendered =~ ~s(data-auto-scroll="true")
    end
  end

  describe "load_more_history event" do
    test "loads historical lines and updates earliest_offset", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "history_load.log")

      # Create file with many lines
      content =
        1..50
        |> Enum.map(fn i -> "line #{i}" end)
        |> Enum.join("\n")

      File.write!(path, content <> "\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "initial_lines" => 10}
        )

      wait_for_subscription(view)

      # Initially should have 10 lines (41-50)
      initial_render = render(view)
      assert initial_render =~ "10 lines"
      assert initial_render =~ "line 50"
      assert initial_render =~ "line 41"
      refute initial_render =~ "line 40"

      # Request more history - this is synchronous, render_click returns updated HTML
      rendered = render_click(view, "load_more_history", %{})

      # Line count should increase and earlier lines should be visible
      assert rendered =~ "line 40"
    end

    test "does nothing when earliest_offset is 0", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "history_noop.log")
      File.write!(path, "line 1\nline 2\nline 3\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "initial_lines" => 100}
        )

      wait_for_subscription(view)

      # All lines loaded, earliest_offset should be 0
      initial_render = render(view)
      assert initial_render =~ "3 lines"

      # Request more history (should be a no-op)
      render_click(view, "load_more_history", %{})

      # Line count should remain the same
      rendered = render(view)
      assert rendered =~ "3 lines"
    end
  end

  describe "line ordering" do
    test "initial lines are in chronological order (oldest first)", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "order_initial.log")
      File.write!(path, "first\nsecond\nthird\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Get all line elements in DOM order
      html = render(view)

      # "first" should appear before "second" which should appear before "third"
      first_pos = :binary.match(html, "first") |> elem(0)
      second_pos = :binary.match(html, "second") |> elem(0)
      third_pos = :binary.match(html, "third") |> elem(0)

      assert first_pos < second_pos
      assert second_pos < third_pos
    end

    test "new lines are appended after existing lines", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "order_append.log")
      File.write!(path, "initial\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Add new line
      File.write!(path, "initial\nnew_line\n")

      html = wait_for_content(view, "new_line")

      # "initial" should appear before "new_line"
      initial_pos = :binary.match(html, "initial") |> elem(0)
      new_line_pos = :binary.match(html, "new_line") |> elem(0)

      assert initial_pos < new_line_pos
    end

    test "history is prepended before existing lines", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "order_history.log")

      # Create file with distinct lines
      content = "history_line\nvisible_line\n"
      File.write!(path, content)

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path, "initial_lines" => 1}
        )

      wait_for_subscription(view)

      # Initially only "visible_line" should be shown
      initial_html = render(view)
      assert initial_html =~ "visible_line"
      refute initial_html =~ "history_line"

      # Load history
      render_click(view, "load_more_history", %{})

      html = wait_for_content(view, "history_line")

      # Both should now be present
      assert html =~ "history_line"
      assert html =~ "visible_line"

      # "history_line" should appear BEFORE "visible_line" (chronological order)
      history_pos = :binary.match(html, "history_line") |> elem(0)
      visible_pos = :binary.match(html, "visible_line") |> elem(0)

      assert history_pos < visible_pos
    end
  end

  describe "data-offset attribute" do
    test "line elements have correct data-offset attributes", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "offset_attr.log")
      # "abc\n" = 4 bytes, so "def" starts at offset 4
      File.write!(path, "abc\ndef\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      rendered = wait_for_subscription(view)

      # First line should have offset 0
      assert rendered =~ ~s(data-offset="0")
      # Second line should have offset 4
      assert rendered =~ ~s(data-offset="4")
    end
  end

  describe "cleanup on unmount" do
    test "unsubscribes from LogMonitorServer when LiveView terminates", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "cleanup.log")
      File.write!(path, "content\n")

      {:ok, view, _html} =
        live_isolated(conn, UnraidWeb.EmbeddedLogMonitorLive,
          session: %{"path" => path}
        )

      wait_for_subscription(view)

      # Server should exist
      expanded_path = Path.expand(path)
      info = LogMonitorServer.get_info(expanded_path)
      assert info != nil
      assert info.subscriber_count >= 1

      # Stop the LiveView
      GenServer.stop(view.pid)

      # Wait for server to stop (poll-based instead of fixed sleep)
      assert poll_until(fn -> LogMonitorServer.get_info(expanded_path) == nil end, 200),
             "Server should have stopped after subscriber exited"
    end
  end
end
