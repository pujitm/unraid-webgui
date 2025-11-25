defmodule UnraidView.Docker.DockerClient do
  @moduledoc """
  Thin wrapper over ex_docker_engine_api for Docker operations.

  Provides a simplified interface to the Docker Engine API,
  handling connection setup and error normalization.
  """

  alias DockerEngineAPI.Api.Container
  alias DockerEngineAPI.Api.Image
  alias DockerEngineAPI.Connection

  # Docker socket path - typically /var/run/docker.sock on Linux
  # On macOS with Docker Desktop, it may be at ~/.docker/run/docker.sock
  @socket_paths [
    "/var/run/docker.sock",
    Path.expand("~/.docker/run/docker.sock")
  ]

  @doc """
  Creates a new connection to the Docker daemon.
  Automatically detects and uses the Docker Unix socket.
  """
  def conn do
    socket_path = find_socket()

    # Use hackney's Unix socket support
    # The URL format for hackney Unix sockets is: http+unix://<socket_path_urlencoded>/
    Connection.new(
      base_url: "http+unix://#{URI.encode_www_form(socket_path)}/v1.43",
      recv_timeout: 30_000
    )
  end

  defp find_socket do
    Enum.find(@socket_paths, "/var/run/docker.sock", &File.exists?/1)
  end

  # ---------------------------------------------------------------------------
  # Container Queries
  # ---------------------------------------------------------------------------

  @doc """
  List all containers.

  ## Options
    - `:all` - Show all containers (default: true). When false, only running containers.
    - `:filters` - JSON encoded filters to apply
  """
  def list_containers(opts \\ []) do
    opts = Keyword.put_new(opts, :all, true)
    Container.container_list(conn(), opts)
  end

  @doc """
  Get detailed information about a container.
  """
  def get_container(id) do
    Container.container_inspect(conn(), id)
  end

  # ---------------------------------------------------------------------------
  # Container Actions
  # ---------------------------------------------------------------------------

  @doc """
  Start a stopped container.
  """
  def start_container(id) do
    Container.container_start(conn(), id)
  end

  @doc """
  Stop a running container.

  ## Options
    - `timeout` - Seconds to wait before killing the container (default: 10)
  """
  def stop_container(id, timeout \\ 10) do
    Container.container_stop(conn(), id, t: timeout)
  end

  @doc """
  Restart a container.
  """
  def restart_container(id) do
    Container.container_restart(conn(), id)
  end

  @doc """
  Pause a running container.
  """
  def pause_container(id) do
    Container.container_pause(conn(), id)
  end

  @doc """
  Unpause a paused container.
  """
  def unpause_container(id) do
    Container.container_unpause(conn(), id)
  end

  @doc """
  Remove a container.

  ## Options
    - `:force` - Force removal (default: true)
    - `:v` - Remove volumes (default: false)
  """
  def remove_container(id, opts \\ []) do
    opts = Keyword.put_new(opts, :force, true)
    Container.container_delete(conn(), id, opts)
  end

  @doc """
  Get container logs.

  ## Options
    - `:stdout` - Return stdout (default: true)
    - `:stderr` - Return stderr (default: true)
    - `:tail` - Number of lines to return from the end (default: "all")
    - `:timestamps` - Add timestamps to each log line (default: false)
    - `:follow` - Follow log output (default: false)
  """
  def get_container_logs(id, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:stdout, true)
      |> Keyword.put_new(:stderr, true)

    Container.container_logs(conn(), id, opts)
  end

  # ---------------------------------------------------------------------------
  # Image Queries
  # ---------------------------------------------------------------------------

  @doc """
  List all images.

  ## Options
    - `:all` - Show all images (default: false)
    - `:digests` - Show digest information (default: false)
  """
  def list_images(opts \\ []) do
    Image.image_list(conn(), opts)
  end

  @doc """
  Get detailed information about an image.
  """
  def get_image(id) do
    Image.image_inspect(conn(), id)
  end

  @doc """
  Remove an image.

  ## Options
    - `:force` - Force removal (default: false)
    - `:noprune` - Do not delete untagged parents (default: false)
  """
  def remove_image(id, opts \\ []) do
    Image.image_delete(conn(), id, opts)
  end
end
