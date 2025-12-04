defmodule UnraidWeb.DockerEditLive do
  @moduledoc """
  LiveView for editing Docker container settings.

  Accessed via /docker/:name/edit

  Features:
  - Load existing template or create from running container
  - Form-based editing with validation
  - Section-based UI (Basic, Network, Ports, Volumes, Env, Tailscale)
  - Live validation
  - Save and apply changes
  """

  use UnraidWeb, :live_view

  alias Unraid.Docker
  alias Unraid.Docker.Template

  import UnraidWeb.DockerFormComponents

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    # Subscribe to Docker events for this container
    if connected?(socket) do
      Docker.subscribe_events()
    end

    socket =
      socket
      |> assign(:container_name, name)
      |> assign(:loading, true)
      |> assign(:saving, false)
      |> assign(:update_step, nil)
      |> assign(:update_step_number, 0)
      |> assign(:errors, [])
      |> assign(:available_networks, get_available_networks())

    # Load template async
    {:ok, socket, temporary_assigns: []}
    |> then(fn {:ok, socket, opts} ->
      send(self(), {:load_template, name})
      {:ok, socket, opts}
    end)
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:load_template, name}, socket) do
    case Docker.template_from_container(name) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:form, build_form(template))
         |> assign(:loading, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:errors, ["Failed to load template: #{inspect(reason)}"])
         |> put_flash(:error, "Failed to load container template")}
    end
  end

  @impl true
  def handle_info({:docker_event, %{action: action, container_id: id}}, socket)
      when action in ["start", "die", "stop"] do
    # Container state changed, might want to refresh
    if id == socket.assigns.container_name do
      {:noreply, put_flash(socket, :info, "Container #{action}ed")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:docker_event, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:update_progress, step, step_number}, socket) do
    {:noreply,
     socket
     |> assign(:update_step, step)
     |> assign(:update_step_number, step_number)}
  end

  @impl true
  def handle_info({:update_complete, _result}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:update_step, nil)
     |> assign(:update_step_number, 0)
     |> put_flash(:info, "Container updated successfully")
     |> push_navigate(to: ~p"/docker")}
  end

  @impl true
  def handle_info({:update_failed, error}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:update_step, nil)
     |> assign(:update_step_number, 0)
     |> put_flash(:error, "Update failed: #{format_error(error)}")}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate", params, socket) do
    # Form params come in without a wrapper since we don't use `as:`
    template = params_to_template(params, socket.assigns.template)

    {:noreply,
     socket
     |> assign(:template, template)
     |> assign(:form, build_form(template))}
  end

  @impl true
  def handle_event("save", params, socket) do
    template = params_to_template(params, socket.assigns.template)

    case Template.validate(template) do
      {:ok, _} ->
        # Start async update
        pid = self()

        Task.start(fn ->
          progress_callback = fn step, number ->
            send(pid, {:update_progress, step, number})
          end

          result =
            Docker.update_container_settings(template,
              progress_callback: progress_callback,
              create_paths: true,
              backup: true
            )

          case result do
            {:ok, result} -> send(pid, {:update_complete, result})
            {:error, error} -> send(pid, {:update_failed, error})
          end
        end)

        {:noreply, assign(socket, :saving, true)}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:errors, errors)
         |> put_flash(:error, "Validation failed: #{Enum.join(errors, ", ")}")}
    end
  end

  @impl true
  def handle_event("add_config", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)
    new_config = Template.new_config(type_atom)
    template = Template.add_config(socket.assigns.template, new_config)

    {:noreply,
     socket
     |> assign(:template, template)
     |> assign(:form, build_form(template))}
  end

  @impl true
  def handle_event("remove_config", %{"index" => index}, socket) do
    index = String.to_integer(index)
    template = Template.remove_config(socket.assigns.template, index)

    {:noreply,
     socket
     |> assign(:template, template)
     |> assign(:form, build_form(template))}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6 max-w-4xl">
      <.header>
        Edit Container: {@container_name}
        <:subtitle>Modify container settings and apply changes</:subtitle>
        <:actions>
          <.link navigate={~p"/docker"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
          </.link>
        </:actions>
      </.header>

      <div :if={@loading} class="flex items-center justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <div :if={!@loading && @errors != []} class="alert alert-error mb-4">
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <div>
          <p :for={error <- @errors}>{error}</p>
        </div>
      </div>

      <.form
        :if={!@loading && assigns[:template]}
        for={@form}
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.basic_settings_section form={@form} networks={@available_networks} />

        <.port_mappings_section configs={@template.configs} />

        <.volume_mappings_section configs={@template.configs} />

        <.environment_section configs={@template.configs} />

        <.labels_section configs={@template.configs} />

        <.devices_section configs={@template.configs} />

        <.tailscale_section tailscale={@template.tailscale} />

        <.ui_settings_section form={@form} />

        <.advanced_settings_section form={@form} />

        <.form_actions saving={@saving} cancel_path={~p"/docker"} />
      </.form>

      <.update_progress
        step={@update_step}
        step_number={@update_step_number}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_form(template) do
    to_form(%{
      "name" => template.name,
      "repository" => template.repository,
      "registry" => template.registry,
      "network" => template.network,
      "my_ip" => template.my_ip,
      "shell" => template.shell,
      "privileged" => template.privileged,
      "web_ui" => template.web_ui,
      "icon" => template.icon,
      "overview" => template.overview,
      "cpuset" => template.cpuset,
      "extra_params" => template.extra_params,
      "post_args" => template.post_args
    })
  end

  defp params_to_template(params, existing_template) do
    # Parse configs from form data
    configs = parse_configs_from_params(params)

    # Parse tailscale settings
    tailscale = parse_tailscale_from_params(params, existing_template.tailscale)

    %Template{
      name: params["name"] || existing_template.name,
      repository: params["repository"] || existing_template.repository,
      registry: nilify(params["registry"]),
      network: params["network"] || existing_template.network,
      my_ip: nilify(params["my_ip"]),
      shell: params["shell"] || "sh",
      privileged: params["privileged"] == "true",
      extra_params: nilify(params["extra_params"]),
      post_args: nilify(params["post_args"]),
      cpuset: nilify(params["cpuset"]),
      web_ui: nilify(params["web_ui"]),
      icon: nilify(params["icon"]),
      overview: nilify(params["overview"]),
      category: existing_template.category,
      support: existing_template.support,
      project: existing_template.project,
      template_url: existing_template.template_url,
      donate_text: existing_template.donate_text,
      donate_link: existing_template.donate_link,
      requires: existing_template.requires,
      date_installed: existing_template.date_installed,
      configs: configs,
      tailscale: tailscale
    }
  end

  defp parse_configs_from_params(%{"configs" => configs}) when is_map(configs) do
    configs
    |> Enum.sort_by(fn {key, _} -> String.to_integer(key) end)
    |> Enum.map(fn {_index, config} ->
      %{
        name: config["name"] || "",
        target: config["target"] || "",
        default: config["default"] || "",
        value: config["value"] || "",
        mode: config["mode"] || "",
        type: parse_config_type(config["type"]),
        display: config["display"] || "always",
        required: config["required"] == "true",
        mask: config["mask"] == "true",
        description: config["description"] || ""
      }
    end)
  end

  defp parse_configs_from_params(_), do: []

  defp parse_config_type("port"), do: :port
  defp parse_config_type("path"), do: :path
  defp parse_config_type("variable"), do: :variable
  defp parse_config_type("label"), do: :label
  defp parse_config_type("device"), do: :device
  defp parse_config_type(_), do: :variable

  defp parse_tailscale_from_params(%{"tailscale" => ts}, _existing) when is_map(ts) do
    if ts["enabled"] == "true" do
      %{
        enabled: true,
        hostname: nilify(ts["hostname"]),
        is_exit_node: ts["is_exit_node"] == "true",
        exit_node_ip: nilify(ts["exit_node_ip"]),
        ssh: if(ts["ssh"] == "true", do: "true", else: nil),
        userspace_networking: nilify(ts["userspace_networking"]),
        lan_access: nilify(ts["lan_access"]),
        serve: nilify(ts["serve"]),
        serve_port: nilify(ts["serve_port"]),
        serve_target: nilify(ts["serve_target"]),
        serve_local_path: nilify(ts["serve_local_path"]),
        serve_protocol: nilify(ts["serve_protocol"]),
        serve_protocol_port: nilify(ts["serve_protocol_port"]),
        serve_path: nilify(ts["serve_path"]),
        web_ui: nilify(ts["web_ui"]),
        routes: nilify(ts["routes"]),
        accept_routes: ts["accept_routes"] == "true",
        daemon_params: nilify(ts["daemon_params"]),
        extra_params: nilify(ts["extra_params"]),
        state_dir: nilify(ts["state_dir"]),
        troubleshooting: ts["troubleshooting"] == "true"
      }
    else
      nil
    end
  end

  defp parse_tailscale_from_params(_, existing), do: existing

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(value), do: value

  defp get_available_networks do
    # Return common networks - in production this would query Docker
    [
      {"Bridge", "bridge"},
      {"Host", "host"},
      {"None", "none"}
    ]
  end

  defp format_error({step, reason}) when is_atom(step) do
    "#{step}: #{inspect(reason)}"
  end

  defp format_error(error), do: inspect(error)
end
