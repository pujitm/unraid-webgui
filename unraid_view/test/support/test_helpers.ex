defmodule Unraid.TestHelpers do
  @moduledoc """
  Shared test helper functions for polling, waiting, and async operations.

  These helpers provide poll-based waiting mechanisms that are faster and more
  robust than fixed `Process.sleep` calls. They return as soon as the condition
  is met, with a timeout as a safety net.

  ## Usage

      use Unraid.TestHelpers

  Or import specific functions:

      import Unraid.TestHelpers, only: [poll_until: 2, poll_until: 3]
  """

  @doc """
  Polls until a condition becomes true or timeout is reached.

  Returns `true` if condition was met, `false` if timeout occurred.
  Much faster than fixed sleeps when the condition completes quickly.

  ## Parameters
    - `condition_fn` - Zero-arity function returning truthy/falsy value
    - `timeout` - Maximum time to wait in milliseconds
    - `opts` - Options:
      - `:interval` - Poll interval in ms (default: 5)

  ## Examples

      # Wait for a process to stop
      assert poll_until(fn -> not Process.alive?(pid) end, 100)

      # Wait for a file to exist
      poll_until(fn -> File.exists?(path) end, 500, interval: 10)

      # Use in assertion with message
      assert poll_until(fn -> GenServer.call(pid, :ready?) end, 200),
             "Server should be ready"
  """
  @spec poll_until((() -> boolean()), non_neg_integer(), keyword()) :: boolean()
  def poll_until(condition_fn, timeout, opts \\ []) do
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_until(condition_fn, deadline, interval)
  end

  defp do_poll_until(condition_fn, deadline, interval) do
    cond do
      condition_fn.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(interval)
        do_poll_until(condition_fn, deadline, interval)
    end
  end

  @doc """
  Polls until a value-returning function returns a non-nil result.

  Returns `{:ok, value}` if a value was found, `:timeout` otherwise.
  Useful when you need to capture the result, not just check a condition.

  ## Parameters
    - `value_fn` - Zero-arity function returning nil or a value
    - `timeout` - Maximum time to wait in milliseconds
    - `opts` - Options:
      - `:interval` - Poll interval in ms (default: 5)

  ## Examples

      # Wait for a message in a GenServer state
      {:ok, messages} = poll_for_value(fn ->
        state = :sys.get_state(pid)
        if state.messages != [], do: state.messages
      end, 200)

      # Wait for file content to appear
      case poll_for_value(fn ->
        case File.read(path) do
          {:ok, content} when content != "" -> content
          _ -> nil
        end
      end, 500) do
        {:ok, content} -> # use content
        :timeout -> flunk("File never got content")
      end
  """
  @spec poll_for_value((() -> term()), non_neg_integer(), keyword()) ::
          {:ok, term()} | :timeout
  def poll_for_value(value_fn, timeout, opts \\ []) do
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_for_value(value_fn, deadline, interval)
  end

  defp do_poll_for_value(value_fn, deadline, interval) do
    case value_fn.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(interval)
          do_poll_for_value(value_fn, deadline, interval)
        end

      value ->
        {:ok, value}
    end
  end

  @doc """
  Configures fast polling for tests by setting application env.

  Call this in your test setup to speed up polling-based operations.
  Returns an on_exit callback that restores the original value.

  ## Parameters
    - `key` - The application env key (under `:unraid` app)
    - `value` - The fast value to use during tests

  ## Example

      setup do
        configure_fast_polling(:log_monitor_poll_interval, 20)
        :ok
      end
  """
  @spec configure_fast_polling(atom(), term()) :: :ok
  def configure_fast_polling(key, value) do
    original = Application.get_env(:unraid, key)
    Application.put_env(:unraid, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      if original do
        Application.put_env(:unraid, key, original)
      else
        Application.delete_env(:unraid, key)
      end
    end)

    :ok
  end

  @doc """
  Macro for importing test helpers into a test module.
  """
  defmacro __using__(_opts) do
    quote do
      import Unraid.TestHelpers
    end
  end
end

defmodule Unraid.TestHelpers.LiveView do
  @moduledoc """
  LiveView-specific test helpers for polling rendered content.

  These helpers work with Phoenix.LiveViewTest views to poll until
  rendered content matches expectations.

  ## Usage

      use Unraid.TestHelpers.LiveView

  Or import specific functions:

      import Unraid.TestHelpers.LiveView, only: [wait_for_content: 2]
  """

  import Phoenix.LiveViewTest, only: [render: 1]

  @doc """
  Polls until the rendered view contains the expected pattern.

  Returns the HTML when pattern is found, or the last rendered HTML on timeout.
  Useful for waiting on async updates to appear in the view.

  ## Parameters
    - `view` - LiveView test view
    - `pattern` - String or regex to match against rendered HTML
    - `opts` - Options:
      - `:timeout` - Maximum time to wait in ms (default: 200)
      - `:interval` - Poll interval in ms (default: 5)

  ## Examples

      # Wait for a success message
      html = wait_for_content(view, "Operation complete")
      assert html =~ "Operation complete"

      # Wait with custom timeout
      html = wait_for_content(view, ~r/\\d+ items/, timeout: 500)

      # Pattern matching
      assert wait_for_content(view, "loaded") =~ "Data loaded successfully"
  """
  @spec wait_for_content(pid() | struct(), String.t() | Regex.t(), keyword()) :: String.t()
  def wait_for_content(view, pattern, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 200)
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_content(view, pattern, deadline, interval)
  end

  defp do_wait_for_content(view, pattern, deadline, interval) do
    html = render(view)

    cond do
      html =~ pattern ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        html

      true ->
        Process.sleep(interval)
        do_wait_for_content(view, pattern, deadline, interval)
    end
  end

  @doc """
  Polls until the rendered view does NOT contain the pattern.

  Useful for waiting until loading states or temporary content disappears.

  ## Parameters
    - `view` - LiveView test view
    - `pattern` - String or regex that should NOT be in the HTML
    - `opts` - Options:
      - `:timeout` - Maximum time to wait in ms (default: 200)
      - `:interval` - Poll interval in ms (default: 5)

  ## Examples

      # Wait for loading indicator to disappear
      html = wait_for_absence(view, "Loading...")
      refute html =~ "Loading..."
  """
  @spec wait_for_absence(pid() | struct(), String.t() | Regex.t(), keyword()) :: String.t()
  def wait_for_absence(view, pattern, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 200)
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_absence(view, pattern, deadline, interval)
  end

  defp do_wait_for_absence(view, pattern, deadline, interval) do
    html = render(view)

    cond do
      not (html =~ pattern) ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        html

      true ->
        Process.sleep(interval)
        do_wait_for_absence(view, pattern, deadline, interval)
    end
  end

  @doc """
  Macro for importing LiveView test helpers into a test module.
  """
  defmacro __using__(_opts) do
    quote do
      import Unraid.TestHelpers.LiveView
    end
  end
end

