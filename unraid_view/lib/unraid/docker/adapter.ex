defmodule Unraid.Docker.Adapter do
  @moduledoc """
  Implementation layer for Docker communication.

  Handles both Docker Engine API (via ex_docker_engine_api) and CLI operations.
  This module provides the low-level interface to Docker, used by the
  `Unraid.Docker` context module.
  """

  alias DockerEngineAPI.Api.Container
  alias DockerEngineAPI.Api.Image
  alias DockerEngineAPI.Connection
  alias Unraid.Parse

  # Docker socket path - typically /var/run/docker.sock on Linux
  # On macOS with Docker Desktop, it may be at ~/.docker/run/docker.sock
  @socket_paths [
    "/var/run/docker.sock",
    Path.expand("~/.docker/run/docker.sock")
  ]

  # ---------------------------------------------------------------------------
  # Connection
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # CLI Operations - Exec
  # ---------------------------------------------------------------------------

  @doc """
  Execute a command inside a running container.

  Returns `{:ok, output}` or `{:error, reason}`.

  ## Options
    - `:timeout` - Command timeout in milliseconds (default: 5000)

  ## Examples

      exec_in_container("my-container", ["tailscale", "status", "--json"])
      exec_in_container("my-container", ["/bin/sh", "-c", "echo hello"])
  """
  def exec_in_container(container_name, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        # Clean container name (remove leading /)
        clean_name = String.trim_leading(container_name, "/")
        args = ["exec", clean_name | command]

        # Use Task.async/await for timeout support since System.cmd doesn't have a timeout option
        task =
          Task.async(fn ->
            System.cmd(docker_path, args, stderr_to_stdout: true)
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            {:ok, output}

          {:ok, {error, code}} ->
            {:error, {:exit_code, code, error}}

          nil ->
            {:error, :timeout}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # CLI Operations - Stats
  # ---------------------------------------------------------------------------

  @doc """
  Fetch current stats for all running containers via CLI.

  Returns `{:ok, stats}` or `{:error, reason}` where stats is a list of maps:

      [
        %{id: "abc123", name: "nginx", cpu_percent: 5.2, memory_usage: "256MiB / 1GiB", memory_percent: 25.0},
        ...
      ]
  """
  def get_stats do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        # Use --no-stream for a single snapshot
        args = [
          "stats",
          "--no-stream",
          "--no-trunc",
          "--format",
          "{{.ID}};{{.Name}};{{.CPUPerc}};{{.MemUsage}};{{.MemPerc}}"
        ]

        case System.cmd(docker_path, args, stderr_to_stdout: true) do
          {output, 0} ->
            stats =
              output
              |> String.split("\n", trim: true)
              |> Enum.map(&parse_stats_line/1)
              |> Enum.reject(&is_nil/1)

            {:ok, stats}

          {error, _code} ->
            {:error, error}
        end
    end
  end

  defp parse_stats_line(line) do
    line = String.trim(line)

    case String.split(line, ";") do
      [id, name, cpu, mem_usage, mem_perc] when id != "" ->
        %{
          id: String.slice(id, 0, 12),
          name: name,
          cpu_percent: parse_percent(cpu),
          memory_usage: mem_usage,
          memory_percent: parse_percent(mem_perc)
        }

      _ ->
        nil
    end
  end

  defp parse_percent(str), do: Parse.percent_or_default(str, 0.0)

  # ---------------------------------------------------------------------------
  # CLI Operations - Events
  # ---------------------------------------------------------------------------

  @doc """
  Open a port for streaming Docker events.

  Returns `{:ok, port}` or `{:error, reason}`.

  The port will emit container lifecycle events in JSON format.
  Caller is responsible for managing the port lifecycle.
  """
  def open_events_port do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        # Filter to container events only, output JSON for reliable parsing
        port =
          Port.open(
            {:spawn_executable, docker_path},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              args: [
                "events",
                "--filter",
                "type=container",
                "--format",
                "{{json .}}"
              ]
            ]
          )

        {:ok, port}
    end
  end
end
