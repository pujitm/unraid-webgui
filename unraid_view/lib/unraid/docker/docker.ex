defmodule Unraid.Docker do
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
      Unraid.Docker.subscribe()

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
  alias Unraid.Docker.{Adapter, Container, Template, TemplateAdapter, ContainerUpdater}
  alias Unraid.EventLog
  alias Unraid.Parse

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
    PubSub.subscribe(Unraid.PubSub, @containers_topic)
    PubSub.subscribe(Unraid.PubSub, @stats_topic)
    PubSub.subscribe(Unraid.PubSub, @events_topic)
  end

  @doc """
  Subscribe to container list updates only.
  """
  def subscribe_containers do
    PubSub.subscribe(Unraid.PubSub, @containers_topic)
  end

  @doc """
  Subscribe to stats updates only.
  """
  def subscribe_stats do
    PubSub.subscribe(Unraid.PubSub, @stats_topic)
  end

  @doc """
  Subscribe to Docker events only.
  """
  def subscribe_events do
    PubSub.subscribe(Unraid.PubSub, @events_topic)
  end

  # ---------------------------------------------------------------------------
  # PubSub Broadcasting (used by servers)
  # ---------------------------------------------------------------------------

  @doc false
  def broadcast_containers(containers) do
    PubSub.broadcast(Unraid.PubSub, @containers_topic, {:containers_updated, containers})
  end

  @doc false
  def broadcast_stats(stats) do
    PubSub.broadcast(Unraid.PubSub, @stats_topic, {:stats_updated, stats})
  end

  @doc false
  def broadcast_event(event) do
    PubSub.broadcast(Unraid.PubSub, @events_topic, {:docker_event, event})
  end

  # ---------------------------------------------------------------------------
  # Container Queries
  # ---------------------------------------------------------------------------

  @doc """
  List all containers.

  Returns a list of `%Container{}` structs sorted by name.

  ## Options
    - `:enrich_with_templates` - When true, stopped containers will have their
      port information populated from their XML templates (default: true)
  """
  def list_containers(opts \\ []) do
    enrich_with_templates = Keyword.get(opts, :enrich_with_templates, true)

    case Adapter.list_containers(opts) do
      {:ok, containers} ->
        containers
        |> Enum.map(&Container.from_api/1)
        |> maybe_enrich_with_template_ports(enrich_with_templates)
        |> Enum.sort_by(& &1.name, :asc)

      {:error, _reason} ->
        []
    end
  end

  defp maybe_enrich_with_template_ports(containers, false), do: containers

  defp maybe_enrich_with_template_ports(containers, true) do
    Enum.map(containers, &enrich_container_with_template_ports/1)
  end

  @doc """
  Enrich a container with port information from its XML template.

  This is useful for stopped containers where the Docker API doesn't return
  port mappings. If the container already has port data or the template
  doesn't exist, the container is returned unchanged.
  """
  def enrich_container_with_template_ports(%Container{} = container) do
    # Only enrich if container is stopped and has no ports
    if container.state != :running and (container.ports == nil or container.ports == []) do
      case get_template(container.name) do
        {:ok, template} ->
          template_ports = ports_from_template(template)
          %{container | ports: template_ports}

        {:error, _} ->
          container
      end
    else
      container
    end
  end

  @doc """
  Convert template port configs to container port mappings.

  Returns a list of port mappings in the same format as `Container.ports`.
  """
  def ports_from_template(%Template{} = template) do
    template
    |> Template.ports()
    |> Enum.map(fn config ->
      %{
        private: Parse.integer_or_nil(config.target),
        public: Parse.integer_or_nil(config.value),
        type: Parse.port_type_or_default(config.mode, "tcp"),
        ip: nil
      }
    end)
    |> Enum.filter(fn port -> port.private != nil end)
  end

  @doc """
  Get a single container by ID.
  """
  def get_container(id) do
    case Adapter.get_container(id) do
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
    case Adapter.start_container(id) do
      {:ok, _} ->
        emit_container_event(id, "start")
        :ok

      :ok ->
        emit_container_event(id, "start")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop a running container.
  """
  def stop_container(id, timeout \\ 10) do
    case Adapter.stop_container(id, timeout) do
      {:ok, _} ->
        emit_container_event(id, "stop")
        :ok

      :ok ->
        emit_container_event(id, "stop")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Restart a container.
  """
  def restart_container(id) do
    case Adapter.restart_container(id) do
      {:ok, _} ->
        emit_container_event(id, "restart")
        :ok

      :ok ->
        emit_container_event(id, "restart")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pause a running container.
  """
  def pause_container(id) do
    case Adapter.pause_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resume a paused container.
  """
  def resume_container(id) do
    case Adapter.unpause_container(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove a container.
  """
  def remove_container(id) do
    case Adapter.remove_container(id) do
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

    case Adapter.get_container_logs(container_id, opts) do
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
    case Adapter.list_images(opts) do
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
    case Adapter.remove_image(id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Template Operations
  # ---------------------------------------------------------------------------

  @doc """
  Get the XML template for a container.

  Returns `{:ok, template}` or `{:error, reason}`.
  """
  def get_template(container_name) do
    TemplateAdapter.read_template(container_name)
  end

  @doc """
  List all available templates.

  Returns a list of `{name, path}` tuples.
  """
  def list_templates do
    TemplateAdapter.list_templates()
  end

  @doc """
  Check if a template exists for the container.
  """
  def template_exists?(container_name) do
    TemplateAdapter.template_exists?(container_name)
  end

  @doc """
  Save a template without updating the container.

  Useful for saving changes before applying them.
  """
  def save_template(%Template{} = template) do
    TemplateAdapter.write_template(template)
  end

  @doc """
  Delete a template file.
  """
  def delete_template(container_name) do
    TemplateAdapter.delete_template(container_name)
  end

  # ---------------------------------------------------------------------------
  # Container Settings Update
  # ---------------------------------------------------------------------------

  @doc """
  Update a container with new settings.

  This will:
  1. Save the template to XML
  2. Stop and remove the old container
  3. Create and start the new container

  ## Options
    - `:pull_image` - Pull the image before creating (default: false)
    - `:start_after_create` - Start container after creating (default: true)
    - `:create_paths` - Create host paths for volumes if missing (default: true)
    - `:backup` - Backup existing template before saving (default: false)
    - `:stop_timeout` - Seconds to wait when stopping (default: 10)
    - `:progress_callback` - Function called with `(step, step_number)` for progress updates

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def update_container_settings(%Template{} = template, opts \\ []) do
    ContainerUpdater.update_container(template, opts)
  end

  @doc """
  Create a new container from a template.

  Unlike `update_container_settings/2`, this does not stop or remove an existing
  container. Use this for creating brand new containers.

  Emits an event to the event log with progress updates.

  ## Options
    - `:pull_image` - Pull the image before creating (default: false)
    - `:start_after_create` - Start container after creating (default: true)
    - `:create_paths` - Create host paths for volumes if missing (default: true)
    - `:progress_callback` - Function called with `(step, step_number)` for progress updates

  Returns `{:ok, result}` or `{:error, reason}`.
  The result includes `:event_id` which can be used to track the event in the event log.
  """
  def create_container(%Template{} = template, opts \\ []) do
    ContainerUpdater.create_new_container(template, opts)
  end

  @doc """
  Preview the docker create command for a template without executing.

  Useful for showing users what command will be run.
  """
  def preview_update(%Template{} = template, opts \\ []) do
    ContainerUpdater.dry_run(template, opts)
  end

  @doc """
  Validate a template for required fields and configuration.
  """
  def validate_template(%Template{} = template) do
    Template.validate(template)
  end

  @doc """
  Create a new template struct for a container based on its current running state.

  This is useful for creating a template from an existing container that
  may not have an XML template file yet.
  """
  def template_from_container(container_name) do
    with {:ok, container} <- get_container(container_name) do
      # Try to load existing template first
      case get_template(container_name) do
        {:ok, template} ->
          {:ok, template}

        {:error, _} ->
          # No template exists, create a basic one from container info
          {:ok, create_basic_template(container)}
      end
    end
  end

  defp create_basic_template(container) do
    %Template{
      name: container.name,
      repository: container.image,
      registry: nil,
      network: container.network_mode || "bridge",
      my_ip: nil,
      shell: container.shell || "sh",
      privileged: false,
      extra_params: nil,
      post_args: nil,
      cpuset: nil,
      web_ui: container.web_ui,
      icon: container.icon,
      overview: nil,
      category: nil,
      support: nil,
      project: nil,
      template_url: nil,
      donate_text: nil,
      donate_link: nil,
      requires: nil,
      date_installed: :os.system_time(:second),
      configs: build_configs_from_container(container),
      tailscale:
        if container.tailscale_enabled do
          %{
            enabled: true,
            hostname: container.tailscale_hostname,
            is_exit_node: false,
            exit_node_ip: nil,
            ssh: nil,
            userspace_networking: nil,
            lan_access: nil,
            serve: nil,
            serve_port: nil,
            serve_target: nil,
            serve_local_path: nil,
            serve_protocol: nil,
            serve_protocol_port: nil,
            serve_path: nil,
            web_ui: container.tailscale_webui_template,
            routes: nil,
            accept_routes: false,
            daemon_params: nil,
            extra_params: nil,
            state_dir: nil,
            troubleshooting: false
          }
        else
          nil
        end
    }
  end

  defp build_configs_from_container(container) do
    port_configs =
      Enum.map(container.ports || [], fn port ->
        %{
          name: "Port #{port.private}",
          target: to_string(port.private),
          default: to_string(port.public || ""),
          value: to_string(port.public || ""),
          mode: port.type || "tcp",
          type: :port,
          display: "always",
          required: false,
          mask: false,
          description: ""
        }
      end)

    volume_configs =
      Enum.map(container.volumes || [], fn volume ->
        [host, container_path | _] = String.split(volume, ":", parts: 3)

        %{
          name: "Path #{container_path}",
          target: container_path,
          default: host,
          value: host,
          mode: "rw",
          type: :path,
          display: "always",
          required: false,
          mask: false,
          description: ""
        }
      end)

    port_configs ++ volume_configs
  end

  # ---------------------------------------------------------------------------
  # Event Log Helpers
  # ---------------------------------------------------------------------------

  @docker_log_base "/var/lib/docker/containers"

  defp emit_container_event(container_id, action) do
    # Spawn a task to emit the event asynchronously (don't block the action)
    Task.start(fn ->
      case Adapter.get_container(container_id) do
        {:ok, data} ->
          full_id = data."Id" || data["Id"]
          name = normalize_container_name(data."Name" || data["Name"] || data["Names"])
          image = get_container_image(data)

          {:ok, event} =
            EventLog.emit(%{
              source: "docker",
              category: "container.#{action}",
              summary: "Container '#{name}' #{action_past_tense(action)}",
              severity: :info,
              status: :completed,
              metadata: %{
                container_id: String.slice(full_id || "", 0, 12),
                container_name: name,
                image: image
              }
            })

          # Add log file attachment if we have the full container ID
          if full_id do
            log_path = Path.join([@docker_log_base, full_id, "#{full_id}-json.log"])

            EventLog.add_link(event.id, %{
              type: :log_file,
              label: "Container Log",
              target: log_path,
              tailable: action == "start"
            })
          end

        {:error, _reason} ->
          # Container not found (might have been removed), emit event with limited info
          EventLog.emit(%{
            source: "docker",
            category: "container.#{action}",
            summary: "Container #{action_past_tense(action)}",
            severity: :info,
            status: :completed,
            metadata: %{
              container_id: container_id
            }
          })
      end
    end)
  end

  defp normalize_container_name(nil), do: "unknown"
  defp normalize_container_name("/" <> name), do: name
  defp normalize_container_name([name | _]) when is_binary(name), do: normalize_container_name(name)
  defp normalize_container_name(name) when is_binary(name), do: name
  defp normalize_container_name(_), do: "unknown"

  defp get_container_image(data) do
    config = data."Config" || data["Config"]

    cond do
      config && (config."Image" || config["Image"]) ->
        config."Image" || config["Image"]

      data."Image" || data["Image"] ->
        data."Image" || data["Image"]

      true ->
        "unknown"
    end
  end

  defp action_past_tense("start"), do: "started"
  defp action_past_tense("stop"), do: "stopped"
  defp action_past_tense("restart"), do: "restarted"
  defp action_past_tense("pause"), do: "paused"
  defp action_past_tense("unpause"), do: "resumed"
  defp action_past_tense("remove"), do: "removed"
  defp action_past_tense(action), do: action
end
