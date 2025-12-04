defmodule Unraid.Docker.ContainerUpdater do
  @moduledoc """
  Orchestrates the container update workflow.

  The update flow:
  1. Validate the template
  2. (Optional) Backup existing template
  3. Save template to XML file
  4. Stop existing container (gracefully)
  5. Remove existing container
  6. (Optional) Pull image if needed
  7. Create new container
  8. Start new container
  9. Broadcast update event

  This module maintains backwards compatibility with the webgui update process.
  """

  alias Unraid.Docker.{Adapter, Template, TemplateAdapter, CommandBuilder}

  require Logger

  @type step ::
          :validating
          | :backing_up
          | :saving_template
          | :stopping_container
          | :removing_container
          | :pulling_image
          | :creating_container
          | :starting_container
          | :done

  @type progress_callback :: (step(), non_neg_integer() -> any())

  @type result :: %{
          container_id: String.t(),
          steps_completed: [step()],
          command: String.t()
        }

  @type update_opts :: [
          pull_image: boolean(),
          start_after_create: boolean(),
          create_paths: boolean(),
          backup: boolean(),
          stop_timeout: non_neg_integer(),
          progress_callback: progress_callback(),
          timezone: String.t(),
          hostname: String.t(),
          pid_limit: non_neg_integer(),
          network_drivers: map()
        ]

  @default_stop_timeout 10

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
    - `:timezone` - Timezone for container (default: from system)
    - `:hostname` - Host name for container env (default: "Tower")
    - `:pid_limit` - Container PID limit (default: 2048)
    - `:network_drivers` - Map of network names to driver types

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def update_container(%Template{} = template, opts \\ []) do
    progress = Keyword.get(opts, :progress_callback, fn _, _ -> :ok end)
    start_after = Keyword.get(opts, :start_after_create, true)
    pull = Keyword.get(opts, :pull_image, false)
    backup = Keyword.get(opts, :backup, false)

    steps_completed = []

    with {:ok, _} <- step(:validating, 1, progress, fn -> validate_template(template) end),
         steps_completed = [:validating | steps_completed],
         {:ok, _} <- step(:backing_up, 2, progress, fn -> maybe_backup(template, backup) end),
         steps_completed = [:backing_up | steps_completed],
         {:ok, _} <- step(:saving_template, 3, progress, fn -> save_template(template) end),
         steps_completed = [:saving_template | steps_completed],
         {:ok, _} <- step(:stopping_container, 4, progress, fn -> stop_container(template.name, opts) end),
         steps_completed = [:stopping_container | steps_completed],
         {:ok, _} <- step(:removing_container, 5, progress, fn -> remove_container(template.name) end),
         steps_completed = [:removing_container | steps_completed],
         {:ok, _} <- step(:pulling_image, 6, progress, fn -> maybe_pull_image(template.repository, pull) end),
         steps_completed = [:pulling_image | steps_completed],
         {:ok, command_result} <- step(:creating_container, 7, progress, fn -> create_container(template, opts) end),
         steps_completed = [:creating_container | steps_completed],
         {:ok, _} <- step(:starting_container, 8, progress, fn -> maybe_start_container(template.name, start_after) end),
         steps_completed = [:starting_container | steps_completed],
         :ok <- step(:done, 9, progress, fn -> broadcast_update(template.name) end) do
      {:ok,
       %{
         container_id: template.name,
         steps_completed: Enum.reverse([:done | steps_completed]),
         command: command_result.command
       }}
    else
      {:error, {:step_failed, step_name, reason}} ->
        Logger.error("Container update failed at step #{step_name}: #{inspect(reason)}")
        {:error, {step_name, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Dry run - validate and build command without executing.

  Useful for previewing changes before applying.
  """
  def dry_run(%Template{} = template, opts \\ []) do
    with {:ok, _} <- validate_template(template),
         {:ok, command_result} <- CommandBuilder.build_create_command(template, opts) do
      {:ok,
       %{
         valid: true,
         command: command_result.command,
         args: command_result.args,
         name: template.name,
         repository: template.repository
       }}
    end
  end

  @doc """
  Validate a template before update.

  Returns `:ok` or `{:error, reasons}`.
  """
  def validate(%Template{} = template) do
    case Template.validate(template) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Step Helpers
  # ---------------------------------------------------------------------------

  defp step(name, number, progress_callback, fun) do
    progress_callback.(name, number)

    case fun.() do
      :ok -> {:ok, nil}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:step_failed, name, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow Steps
  # ---------------------------------------------------------------------------

  defp validate_template(template) do
    Template.validate(template)
  end

  defp maybe_backup(_template, false), do: {:ok, nil}

  defp maybe_backup(template, true) do
    if TemplateAdapter.template_exists?(template.name) do
      TemplateAdapter.backup_template(template.name)
    else
      {:ok, nil}
    end
  end

  defp save_template(template) do
    case TemplateAdapter.write_template(template) do
      :ok -> {:ok, nil}
      error -> error
    end
  end

  defp stop_container(name, opts) do
    timeout = Keyword.get(opts, :stop_timeout, @default_stop_timeout)

    # Check if container exists and is running
    case Adapter.get_container(name) do
      {:ok, container} ->
        state = get_in(container, ["State", "Status"]) || ""

        if state in ["running", "paused"] do
          case Adapter.stop_container(name, timeout) do
            {:ok, _} -> {:ok, nil}
            # Container might have already stopped
            {:error, %{status: 304}} -> {:ok, nil}
            {:error, %{status: 404}} -> {:ok, nil}
            error -> error
          end
        else
          {:ok, nil}
        end

      {:error, %{status: 404}} ->
        # Container doesn't exist, that's fine
        {:ok, nil}

      error ->
        error
    end
  end

  defp remove_container(name) do
    case Adapter.remove_container(name, force: true) do
      {:ok, _} -> {:ok, nil}
      {:error, %{status: 404}} -> {:ok, nil}
      error -> error
    end
  end

  defp maybe_pull_image(_repository, false), do: {:ok, nil}

  defp maybe_pull_image(repository, true) do
    # Add :latest tag if not specified
    image =
      if String.contains?(repository, ":") do
        repository
      else
        "#{repository}:latest"
      end

    case pull_image(image) do
      :ok -> {:ok, nil}
      error -> error
    end
  end

  defp pull_image(image) do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        args = ["pull", image]

        case System.cmd(docker_path, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {error, _code} -> {:error, {:pull_failed, error}}
        end
    end
  end

  defp create_container(template, opts) do
    command_opts =
      opts
      |> Keyword.take([:timezone, :hostname, :pid_limit, :network_drivers, :create_paths])
      |> Keyword.put_new(:create_paths, true)

    with {:ok, command_result} <- CommandBuilder.build_create_command(template, command_opts) do
      case execute_create_command(command_result.command) do
        {:ok, container_id} ->
          {:ok, Map.put(command_result, :container_id, container_id)}

        error ->
          error
      end
    end
  end

  defp execute_create_command(command) do
    # The command starts with "docker create", we execute it via shell
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      _docker_path ->
        # Execute via shell to handle quoting properly
        case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
          {output, 0} ->
            container_id = output |> String.trim() |> String.slice(0, 12)
            {:ok, container_id}

          {error, code} ->
            {:error, {:create_failed, code, error}}
        end
    end
  end

  defp maybe_start_container(_name, false), do: {:ok, nil}

  defp maybe_start_container(name, true) do
    case Adapter.start_container(name) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  defp broadcast_update(name) do
    # Broadcast via the Docker context PubSub
    Unraid.Docker.broadcast_event(%{
      action: "update",
      container_id: name,
      timestamp: DateTime.utc_now()
    })

    :ok
  end
end
