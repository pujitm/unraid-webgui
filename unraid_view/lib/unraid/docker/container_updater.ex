defmodule Unraid.Docker.ContainerUpdater do
  @moduledoc """
  Orchestrates container create/update workflows.

  Supports two modes:
  - `update_container/2` - Stop, remove, then recreate an existing container
  - `create_new_container/2` - Create a brand new container

  Both modes emit events to the event log for progress tracking.
  """

  alias Unraid.Docker.{Adapter, Template, TemplateAdapter, CommandBuilder}
  alias Unraid.EventLog

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
          command: String.t(),
          event_id: String.t() | nil
        }

  @type opts :: [
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

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Update a container with new settings.

  Stops and removes the existing container, then creates a new one.

  ## Options
    - `:pull_image` - Pull the image before creating (default: false)
    - `:start_after_create` - Start container after creating (default: true)
    - `:create_paths` - Create host paths for volumes if missing (default: true)
    - `:backup` - Backup existing template before saving (default: false)
    - `:stop_timeout` - Seconds to wait when stopping (default: 10)
    - `:progress_callback` - Function called with `(step, step_number)`
  """
  def update_container(%Template{} = template, opts \\ []) do
    run_workflow(template, opts, :update)
  end

  @doc """
  Create a new container from a template.

  Unlike `update_container/2`, this does not stop or remove an existing container.

  ## Options
    - `:pull_image` - Pull the image before creating (default: false)
    - `:start_after_create` - Start container after creating (default: true)
    - `:create_paths` - Create host paths for volumes if missing (default: true)
    - `:progress_callback` - Function called with `(step, step_number)`
  """
  def create_new_container(%Template{} = template, opts \\ []) do
    run_workflow(template, opts, :create)
  end

  @doc """
  Dry run - validate and build command without executing.
  """
  def dry_run(%Template{} = template, opts \\ []) do
    with {:ok, _} <- Template.validate(template),
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
  """
  def validate(%Template{} = template) do
    case Template.validate(template) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow Engine
  # ---------------------------------------------------------------------------

  defp run_workflow(template, opts, mode) do
    progress_cb = Keyword.get(opts, :progress_callback, fn _, _ -> :ok end)
    steps = build_steps(template, opts, mode)
    event = maybe_create_event(template, mode)

    context = %{
      template: template,
      opts: opts,
      mode: mode,
      event_id: event && event.id,
      steps_completed: [],
      command: nil
    }

    result = execute_steps(steps, context, progress_cb)

    case result do
      {:ok, ctx} ->
        if ctx.event_id, do: complete_event(ctx.event_id, template.name)

        {:ok,
         %{
           container_id: template.name,
           steps_completed: Enum.reverse(ctx.steps_completed),
           command: ctx.command,
           event_id: ctx.event_id
         }}

      {:error, step_name, reason, ctx} ->
        Logger.error("Container #{mode} failed at #{step_name}: #{inspect(reason)}")
        if ctx.event_id, do: fail_event(ctx.event_id, step_name, reason)
        {:error, {step_name, reason}}
    end
  end

  defp build_steps(_template, opts, mode) do
    pull? = Keyword.get(opts, :pull_image, false)
    start? = Keyword.get(opts, :start_after_create, true)
    backup? = Keyword.get(opts, :backup, false)

    base_steps = [{:validating, &validate_step/1}]

    update_steps =
      if mode == :update do
        [
          {:backing_up, &backup_step(&1, backup?)},
          {:saving_template, &save_template_step/1},
          {:stopping_container, &stop_container_step/1},
          {:removing_container, &remove_container_step/1}
        ]
      else
        [{:saving_template, &save_template_step/1}]
      end

    create_steps = [
      {:pulling_image, &pull_image_step(&1, pull?)},
      {:creating_container, &create_container_step/1},
      {:starting_container, &start_container_step(&1, start?)},
      {:done, &broadcast_step(&1, mode)}
    ]

    steps = base_steps ++ update_steps ++ create_steps

    # Number the steps
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, fun}, num} -> {name, num, fun} end)
  end

  defp execute_steps([], context, _progress_cb), do: {:ok, context}

  defp execute_steps([{name, num, fun} | rest], context, progress_cb) do
    progress_cb.(name, num)
    update_event_progress(context.event_id, num, length(rest) + num, step_label(name))

    case fun.(context) do
      {:ok, new_context} ->
        new_context = %{new_context | steps_completed: [name | new_context.steps_completed]}
        execute_steps(rest, new_context, progress_cb)

      {:error, reason} ->
        {:error, name, reason, context}
    end
  end

  # ---------------------------------------------------------------------------
  # Step Implementations
  # ---------------------------------------------------------------------------

  defp validate_step(ctx) do
    case Template.validate(ctx.template) do
      {:ok, _} -> {:ok, ctx}
      {:error, reason} -> {:error, reason}
    end
  end

  defp backup_step(ctx, false), do: {:ok, ctx}

  defp backup_step(ctx, true) do
    if TemplateAdapter.template_exists?(ctx.template.name) do
      case TemplateAdapter.backup_template(ctx.template.name) do
        {:ok, _} -> {:ok, ctx}
        error -> error
      end
    else
      {:ok, ctx}
    end
  end

  defp save_template_step(ctx) do
    case TemplateAdapter.write_template(ctx.template) do
      :ok -> {:ok, ctx}
      error -> error
    end
  end

  defp stop_container_step(ctx) do
    timeout = Keyword.get(ctx.opts, :stop_timeout, @default_stop_timeout)
    name = ctx.template.name

    case Adapter.get_container(name) do
      {:ok, container} ->
        state = get_in(container, ["State", "Status"]) || ""

        if state in ["running", "paused"] do
          case Adapter.stop_container(name, timeout) do
            {:ok, _} -> {:ok, ctx}
            {:error, %{status: status}} when status in [304, 404] -> {:ok, ctx}
            error -> error
          end
        else
          {:ok, ctx}
        end

      {:error, %{status: 404}} ->
        {:ok, ctx}

      error ->
        error
    end
  end

  defp remove_container_step(ctx) do
    case Adapter.remove_container(ctx.template.name, force: true) do
      {:ok, _} -> {:ok, ctx}
      {:error, %{status: 404}} -> {:ok, ctx}
      error -> error
    end
  end

  defp pull_image_step(ctx, false), do: {:ok, ctx}

  defp pull_image_step(ctx, true) do
    repo = ctx.template.repository
    image = if String.contains?(repo, ":"), do: repo, else: "#{repo}:latest"

    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      docker_path ->
        case System.cmd(docker_path, ["pull", image], stderr_to_stdout: true) do
          {_output, 0} -> {:ok, ctx}
          {error, _code} -> {:error, {:pull_failed, error}}
        end
    end
  end

  defp create_container_step(ctx) do
    command_opts =
      ctx.opts
      |> Keyword.take([:timezone, :hostname, :pid_limit, :network_drivers, :create_paths])
      |> Keyword.put_new(:create_paths, true)

    with {:ok, command_result} <- CommandBuilder.build_create_command(ctx.template, command_opts),
         {:ok, _container_id} <- execute_docker_command(command_result.command) do
      {:ok, %{ctx | command: command_result.command}}
    end
  end

  defp execute_docker_command(command) do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_not_found}

      _docker_path ->
        case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
          {output, 0} ->
            container_id = output |> String.trim() |> String.slice(0, 12)
            {:ok, container_id}

          {error, code} ->
            {:error, {:create_failed, code, error}}
        end
    end
  end

  defp start_container_step(ctx, false), do: {:ok, ctx}

  defp start_container_step(ctx, true) do
    case Adapter.start_container(ctx.template.name) do
      {:ok, _} -> {:ok, ctx}
      error -> error
    end
  end

  defp broadcast_step(ctx, mode) do
    action = if mode == :update, do: "update", else: "create"

    Unraid.Docker.broadcast_event(%{
      action: action,
      container_id: ctx.template.name,
      timestamp: DateTime.utc_now()
    })

    {:ok, ctx}
  end

  # ---------------------------------------------------------------------------
  # Event Log Helpers
  # ---------------------------------------------------------------------------

  defp maybe_create_event(template, :create) do
    case EventLog.emit(%{
           source: "docker",
           category: "container.create",
           summary: "Creating container: #{template.name}",
           status: :running,
           progress: 0,
           metadata: %{
             container_name: template.name,
             image: template.repository,
             network: template.network
           }
         }) do
      {:ok, event} -> event
      _ -> nil
    end
  end

  defp maybe_create_event(_template, :update), do: nil

  defp update_event_progress(nil, _, _, _), do: :ok

  defp update_event_progress(event_id, current, total, summary) do
    progress = round(current / total * 100)
    EventLog.update(event_id, %{progress: progress, summary: summary})
    :ok
  end

  defp complete_event(event_id, name) do
    EventLog.update(event_id, %{
      status: :completed,
      progress: 100,
      summary: "Container #{name} created successfully"
    })
  end

  defp fail_event(event_id, step_name, reason) do
    EventLog.update(event_id, %{
      status: :failed,
      summary: "Failed at #{step_name}: #{format_error(reason)}"
    })
  end

  defp format_error({:create_failed, _code, msg}), do: String.trim(msg)
  defp format_error({:pull_failed, msg}), do: String.trim(msg)
  defp format_error(reason), do: inspect(reason)

  defp step_label(:validating), do: "Validating template..."
  defp step_label(:backing_up), do: "Creating backup..."
  defp step_label(:saving_template), do: "Saving template..."
  defp step_label(:stopping_container), do: "Stopping container..."
  defp step_label(:removing_container), do: "Removing container..."
  defp step_label(:pulling_image), do: "Pulling image..."
  defp step_label(:creating_container), do: "Creating container..."
  defp step_label(:starting_container), do: "Starting container..."
  defp step_label(:done), do: "Done!"
  defp step_label(_), do: "Processing..."
end
