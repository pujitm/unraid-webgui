defmodule UnraidView.Docker do
  @moduledoc """
  Context for Docker container management.

  Exposes synchronous API functions and PubSub-based async updates
  for real-time UI components.

  ## PubSub Topics

    * `"docker:containers"` - Container list updates (state changes)
    * `"docker:stats"` - High-frequency stats updates (CPU/memory)
    * `"docker:events"` - Docker daemon events (start, stop, etc.)

  ## Usage

      # Subscribe to all Docker updates
      UnraidView.Docker.subscribe()

      # In LiveView handle_info
      def handle_info({:containers_updated, containers}, socket) do
        {:noreply, assign(socket, containers: containers)}
      end

      def handle_info({:stats_updated, stats}, socket) do
        # stats is a list of %{id, cpu_percent, memory_usage, memory_percent}
        {:noreply, update_stats(socket, stats)}
      end

      def handle_info({:docker_event, event}, socket) do
        # event is %{action: "start"|"stop"|..., container_id: id}
        {:noreply, handle_event(socket, event)}
      end
  """

  alias Phoenix.PubSub
  alias UnraidView.Docker.{DockerClient, Container}

  @containers_topic "docker:containers"
  @stats_topic "docker:stats"
  @events_topic "docker:events"

  # ---------------------------------------------------------------------------
  # PubSub Subscriptions
  # ---------------------------------------------------------------------------

  @doc """
  Subscribe to all Docker updates (containers, stats, and events).
  """
  def subscribe do
    PubSub.subscribe(UnraidView.PubSub, @containers_topic)
    PubSub.subscribe(UnraidView.PubSub, @stats_topic)
    PubSub.subscribe(UnraidView.PubSub, @events_topic)
  end

  @doc """
  Subscribe to container list updates only.
  """
  def subscribe_containers do
    PubSub.subscribe(UnraidView.PubSub, @containers_topic)
  end

  @doc """
  Subscribe to stats updates only.
  """
  def subscribe_stats do
    PubSub.subscribe(UnraidView.PubSub, @stats_topic)
  end

  @doc """
  Subscribe to Docker events only.
  """
  def subscribe_events do
    PubSub.subscribe(UnraidView.PubSub, @events_topic)
  end

  # ---------------------------------------------------------------------------
  # PubSub Broadcasting (used by streamers)
  # ---------------------------------------------------------------------------

  @doc false
  def broadcast_containers(containers) do
    PubSub.broadcast(UnraidView.PubSub, @containers_topic, {:containers_updated, containers})
  end

  @doc false
  def broadcast_stats(stats) do
    PubSub.broadcast(UnraidView.PubSub, @stats_topic, {:stats_updated, stats})
  end

  @doc false
  def broadcast_event(event) do
    PubSub.broadcast(UnraidView.PubSub, @events_topic, {:docker_event, event})
  end

  # ---------------------------------------------------------------------------
  # Container Queries
  # ---------------------------------------------------------------------------

  @doc """
  List all containers.

  Returns a list of `%Container{}` structs sorted by name.
  """
  def list_containers(opts \\ []) do
    case DockerClient.list_containers(opts) do
      {:ok, containers} ->
        containers
        |> Enum.map(&Container.from_api/1)
        |> Enum.sort_by(& &1.name, :asc)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Get a single container by ID.
  """
  def get_container(id) do
    case DockerClient.get_container(id) do
      {:ok, data} -> {:ok, Container.from_api(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Container Actions
  # ---------------------------------------------------------------------------

  @doc """
  Start a stopped container.
  """
  def start_container(id) do
    case DockerClient.start_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stop a running container.
  """
  def stop_container(id, timeout \\ 10) do
    case DockerClient.stop_container(id, timeout) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Restart a container.
  """
  def restart_container(id) do
    case DockerClient.restart_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pause a running container.
  """
  def pause_container(id) do
    case DockerClient.pause_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resume a paused container.
  """
  def resume_container(id) do
    case DockerClient.unpause_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove a container.
  """
  def remove_container(id) do
    case DockerClient.remove_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Bulk Operations
  # ---------------------------------------------------------------------------

  @doc """
  Start multiple containers.
  """
  def start_all(container_ids) when is_list(container_ids) do
    Enum.each(container_ids, &start_container/1)
  end

  @doc """
  Stop multiple containers.
  """
  def stop_all(container_ids) when is_list(container_ids) do
    Enum.each(container_ids, &stop_container/1)
  end

  @doc """
  Pause multiple containers.
  """
  def pause_all(container_ids) when is_list(container_ids) do
    Enum.each(container_ids, &pause_container/1)
  end

  @doc """
  Resume multiple paused containers.
  """
  def resume_all(container_ids) when is_list(container_ids) do
    Enum.each(container_ids, &resume_container/1)
  end

  # ---------------------------------------------------------------------------
  # Logs
  # ---------------------------------------------------------------------------

  @doc """
  Get container logs.

  ## Options
    - `:tail` - Number of lines from the end (default: 100)
    - `:timestamps` - Include timestamps (default: true)
  """
  def get_logs(container_id, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:tail, 100)
      |> Keyword.put_new(:timestamps, true)

    case DockerClient.get_container_logs(container_id, opts) do
      {:ok, logs} when is_binary(logs) ->
        logs
        |> String.split("\n", trim: true)
        |> Enum.map(&clean_log_line/1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Docker logs have a header byte for stdout/stderr - strip it if present
  defp clean_log_line(<<_header::binary-size(8), rest::binary>>)
       when byte_size(rest) > 0 do
    rest
  end

  defp clean_log_line(line), do: line

  # ---------------------------------------------------------------------------
  # Image Operations
  # ---------------------------------------------------------------------------

  @doc """
  List all images.
  """
  def list_images(opts \\ []) do
    case DockerClient.list_images(opts) do
      {:ok, images} -> images
      {:error, _} -> []
    end
  end

  @doc """
  List orphan images (not used by any container).
  """
  def list_orphan_images do
    images = list_images()
    containers = list_containers()

    used_image_ids =
      containers
      |> Enum.map(& &1.image_id)
      |> MapSet.new()

    Enum.reject(images, fn image ->
      image_id = String.slice(image["Id"] || "", 7, 12)
      MapSet.member?(used_image_ids, image_id)
    end)
  end

  @doc """
  Remove an image.
  """
  def remove_image(id) do
    case DockerClient.remove_image(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
