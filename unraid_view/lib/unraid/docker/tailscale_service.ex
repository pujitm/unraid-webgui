defmodule Unraid.Docker.TailscaleService do
  @moduledoc """
  GenServer for fetching and caching Tailscale status for Docker containers.

  Provides:
  - Container Tailscale status via `docker exec`
  - DERP map caching (24 hours)
  - Latest version caching (24 hours)
  - Per-container status caching (30 seconds)
  - Lazy loading (status fetched only when requested)
  """

  use GenServer
  require Logger

  alias Unraid.Docker.Adapter
  alias Unraid.Docker.TailscaleStatus

  # Cache TTLs in milliseconds
  @derp_map_ttl_ms 86_400_000
  @version_ttl_ms 86_400_000
  @status_ttl_ms 30_000

  # HTTP timeout
  @http_timeout 3_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get Tailscale status for a container.

  ## Options
    - `:force_refresh` - Bypass cache and fetch fresh status (default: false)

  Returns `{:ok, TailscaleStatus.t()}` or `{:error, reason}`.
  """
  def get_status(container_name, labels, opts \\ []) do
    GenServer.call(__MODULE__, {:get_status, container_name, labels, opts}, 10_000)
  end

  @doc """
  Get the DERP map (cached for 24 hours).

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def get_derp_map do
    GenServer.call(__MODULE__, :get_derp_map, 5_000)
  end

  @doc """
  Get the latest Tailscale version (cached for 24 hours).

  Returns `{:ok, version}` or `{:error, reason}`.
  """
  def get_latest_version do
    GenServer.call(__MODULE__, :get_latest_version, 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      derp_map: nil,
      derp_map_expires_at: 0,
      latest_version: nil,
      version_expires_at: 0,
      status_cache: %{}
    }

    # Schedule periodic cache cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call({:get_status, container_name, labels, opts}, _from, state) do
    force_refresh = Keyword.get(opts, :force_refresh, false)
    cache_key = container_name

    # Check cache first (unless force refresh)
    cached_status =
      if force_refresh do
        nil
      else
        get_cached_status(state, cache_key)
      end

    case cached_status do
      {:ok, status} ->
        {:reply, {:ok, status}, state}

      :miss ->
        # Fetch fresh status
        {status, new_state} = fetch_and_cache_status(container_name, labels, state)
        {:reply, {:ok, status}, new_state}
    end
  end

  @impl true
  def handle_call(:get_derp_map, _from, state) do
    now = System.monotonic_time(:millisecond)

    if state.derp_map && state.derp_map_expires_at > now do
      {:reply, {:ok, state.derp_map}, state}
    else
      case fetch_derp_map() do
        {:ok, derp_map} ->
          new_state = %{
            state
            | derp_map: derp_map,
              derp_map_expires_at: now + @derp_map_ttl_ms
          }

          {:reply, {:ok, derp_map}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:get_latest_version, _from, state) do
    now = System.monotonic_time(:millisecond)

    if state.latest_version && state.version_expires_at > now do
      {:reply, {:ok, state.latest_version}, state}
    else
      case fetch_latest_version() do
        {:ok, version} ->
          new_state = %{
            state
            | latest_version: version,
              version_expires_at: now + @version_ttl_ms
          }

          {:reply, {:ok, version}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    now = System.monotonic_time(:millisecond)

    # Remove expired status entries
    cleaned_cache =
      state.status_cache
      |> Enum.filter(fn {_key, {_status, expires_at}} -> expires_at > now end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | status_cache: cleaned_cache}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers - Status Fetching
  # ---------------------------------------------------------------------------

  defp fetch_and_cache_status(container_name, labels, state) do
    hostname = labels["net.unraid.docker.tailscale.hostname"]
    webui_template = labels["net.unraid.docker.tailscale.webui"]

    # Fetch status from container
    raw_status = exec_tailscale_status(container_name)

    # Get DERP map and latest version (may be cached)
    {derp_map, state} = ensure_derp_map(state)
    {latest_version, state} = ensure_latest_version(state)

    status =
      case raw_status do
        {:ok, raw} ->
          TailscaleStatus.from_raw(raw,
            hostname: hostname,
            webui_template: webui_template,
            derp_map: derp_map,
            latest_version: latest_version
          )

        {:error, _reason} ->
          TailscaleStatus.offline(hostname)
      end

    # Cache the status
    now = System.monotonic_time(:millisecond)
    expires_at = now + @status_ttl_ms
    new_cache = Map.put(state.status_cache, container_name, {status, expires_at})

    {status, %{state | status_cache: new_cache}}
  end

  defp exec_tailscale_status(container_name) do
    command = ["/bin/sh", "-c", "tailscale status --json"]

    case Adapter.exec_in_container(container_name, command, timeout: 5_000) do
      {:ok, output} ->
        parse_tailscale_output(output)

      {:error, reason} ->
        Logger.debug("Failed to get Tailscale status for #{container_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_tailscale_output(output) do
    # Handle potential Docker stream multiplexing or raw JSON
    clean_output = maybe_demux_stream(output)

    case Jason.decode(clean_output) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp maybe_demux_stream(data) when is_binary(data) do
    # Check if the data looks like it starts with JSON
    trimmed = String.trim_leading(data)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      # Already plain JSON
      trimmed
    else
      # Attempt to demux Docker stream format
      # Docker multiplexed streams start with stream type byte (0, 1, or 2)
      # followed by 3 zero bytes, then 4-byte big-endian size
      demux_docker_stream(data)
    end
  end

  defp demux_docker_stream(data) when is_binary(data) do
    demux_docker_stream(data, [])
  end

  defp demux_docker_stream(<<>>, acc), do: Enum.join(Enum.reverse(acc))

  defp demux_docker_stream(<<_stream_type::8, 0, 0, 0, size::32-big, rest::binary>>, acc)
       when size > 0 do
    case rest do
      <<chunk::binary-size(size), remaining::binary>> ->
        demux_docker_stream(remaining, [chunk | acc])

      _ ->
        # Incomplete frame, return what we have
        Enum.join(Enum.reverse([rest | acc]))
    end
  end

  defp demux_docker_stream(data, acc) do
    # Doesn't look like multiplexed stream, return as-is
    Enum.join(Enum.reverse([data | acc]))
  end

  defp get_cached_status(state, cache_key) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.status_cache, cache_key) do
      {status, expires_at} when expires_at > now -> {:ok, status}
      _ -> :miss
    end
  end

  defp ensure_derp_map(state) do
    now = System.monotonic_time(:millisecond)

    if state.derp_map && state.derp_map_expires_at > now do
      {state.derp_map, state}
    else
      case fetch_derp_map() do
        {:ok, derp_map} ->
          new_state = %{
            state
            | derp_map: derp_map,
              derp_map_expires_at: now + @derp_map_ttl_ms
          }

          {derp_map, new_state}

        {:error, _reason} ->
          {nil, state}
      end
    end
  end

  defp ensure_latest_version(state) do
    now = System.monotonic_time(:millisecond)

    if state.latest_version && state.version_expires_at > now do
      {state.latest_version, state}
    else
      case fetch_latest_version() do
        {:ok, version} ->
          new_state = %{
            state
            | latest_version: version,
              version_expires_at: now + @version_ttl_ms
          }

          {version, new_state}

        {:error, _reason} ->
          {nil, state}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers - HTTP Fetching
  # ---------------------------------------------------------------------------

  defp fetch_derp_map do
    url = "https://login.tailscale.com/derpmap/default"

    case http_get(url) do
      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:ok, _} ->
        {:error, :invalid_response}

      {:error, reason} ->
        Logger.warning("Failed to fetch DERP map: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_latest_version do
    url = "https://pkgs.tailscale.com/stable/?mode=json"

    case http_get(url) do
      {:ok, %{"TarballsVersion" => version}} ->
        {:ok, version}

      {:ok, _} ->
        {:error, :invalid_response}

      {:error, reason} ->
        Logger.warning("Failed to fetch Tailscale version: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp http_get(url) do
    # Use Req if available, otherwise fall back to :httpc
    if Code.ensure_loaded?(Req) do
      case Req.get(url, receive_timeout: @http_timeout) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      http_get_httpc(url)
    end
  end

  defp http_get_httpc(url) do
    # Ensure inets is started
    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [{:timeout, @http_timeout}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, {:json_parse_error, reason}}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers - Scheduling
  # ---------------------------------------------------------------------------

  defp schedule_cleanup do
    # Clean up every 5 minutes
    Process.send_after(self(), :cleanup_cache, 300_000)
  end
end
