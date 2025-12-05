defmodule UnraidWeb.DockerAddLive do
  @moduledoc """
  LiveView for adding new Docker containers.

  Accessed via /docker/add

  Supports loading templates via query parameters:
  - `?template=my-nginx` - Load a local template by name
  - `?template_url=https://example.com/template.xml` - Load from external URL

  Features:
  - Blank form or template-based creation
  - Form validation with live feedback
  - Template picker for loading existing templates
  - Paste XML template to import
  - Progress tracking via event log
  """

  use UnraidWeb, :live_view

  alias Unraid.Docker
  alias Unraid.Docker.Template
  alias Unraid.EventLog

  import UnraidWeb.DockerFormComponents

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Docker.subscribe_events()
      EventLog.subscribe_source("docker")
    end

    socket =
      socket
      |> assign(:loading_template, false)
      |> assign(:saving, false)
      |> assign(:create_step, nil)
      |> assign(:create_step_number, 0)
      |> assign(:errors, [])
      |> assign(:available_networks, get_available_networks())
      |> assign(:available_templates, [])
      |> assign(:show_template_picker, false)
      |> assign(:show_xml_import, false)
      |> assign(:show_xml_preview, false)
      |> assign(:xml_input, "")
      |> assign(:start_after_create, true)
      |> assign(:pull_image, false)
      |> assign(:template_load_error, nil)

    # Initialize with empty template, then check for query params
    socket = init_template(socket, params)

    {:ok, socket}
  end

  defp init_template(socket, params) do
    template = Template.new()

    cond do
      # Load from local template name
      params["template"] ->
        load_local_template(socket, params["template"])

      # Load from external URL
      params["template_url"] ->
        load_remote_template(socket, params["template_url"])

      # Default: empty template
      true ->
        socket
        |> assign(:template, template)
        |> assign(:form, build_form(template))
    end
  end

  defp load_local_template(socket, name) do
    case Docker.get_template(name) do
      {:ok, template} ->
        # Clear the name so user must provide a new one (it's a new container)
        template = %{template | name: ""}

        socket
        |> assign(:template, template)
        |> assign(:form, build_form(template))

      {:error, reason} ->
        socket
        |> assign(:template, Template.new())
        |> assign(:form, build_form(Template.new()))
        |> assign(:template_load_error, "Failed to load template '#{name}': #{inspect(reason)}")
    end
  end

  defp load_remote_template(socket, url) do
    socket = assign(socket, :loading_template, true)
    pid = self()

    Task.start(fn ->
      result = fetch_and_parse_template(url)
      send(pid, {:template_loaded, result})
    end)

    socket
    |> assign(:template, Template.new())
    |> assign(:form, build_form(Template.new()))
  end

  defp fetch_and_parse_template(url) do
    # Validate URL scheme
    uri = URI.parse(url)

    if uri.scheme not in ["http", "https"] do
      {:error, "Invalid URL scheme - only HTTP/HTTPS allowed"}
    else
      case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 10_000], body_format: :binary) do
        {:ok, {{_, 200, _}, _headers, body}} ->
          Template.from_xml(to_string(body))

        {:ok, {{_, status, _}, _, _}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:template_loaded, result}, socket) do
    socket = assign(socket, :loading_template, false)

    case result do
      {:ok, template} ->
        # Clear name for new container
        template = %{template | name: ""}

        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:form, build_form(template))}

      {:error, reason} ->
        {:noreply, assign(socket, :template_load_error, "Failed to load template: #{reason}")}
    end
  end

  @impl true
  def handle_info({:docker_event, %{action: action, container_id: name}}, socket)
      when action in ["create", "start"] do
    if name == socket.assigns.template.name do
      {:noreply, put_flash(socket, :info, "Container #{action}d: #{name}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:docker_event, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:event_created, _event}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:event_updated, _event, _changes}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:create_progress, step, step_number}, socket) do
    {:noreply,
     socket
     |> assign(:create_step, step)
     |> assign(:create_step_number, step_number)}
  end

  @impl true
  def handle_info({:create_complete, _result}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:create_step, nil)
     |> assign(:create_step_number, 0)
     |> put_flash(:info, "Container created successfully")
     |> push_navigate(to: ~p"/docker")}
  end

  @impl true
  def handle_info({:create_failed, error}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:create_step, nil)
     |> assign(:create_step_number, 0)
     |> put_flash(:error, "Creation failed: #{format_error(error)}")}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate", params, socket) do
    template = params_to_template(params, socket.assigns.template)

    {:noreply,
     socket
     |> assign(:template, template)
     |> assign(:form, build_form(template))
     |> assign(:share_url, nil)}
  end

  @impl true
  def handle_event("toggle_start_after", _params, socket) do
    {:noreply, assign(socket, :start_after_create, !socket.assigns.start_after_create)}
  end

  @impl true
  def handle_event("toggle_pull_image", _params, socket) do
    {:noreply, assign(socket, :pull_image, !socket.assigns.pull_image)}
  end

  @impl true
  def handle_event("create", params, socket) do
    template = params_to_template(params, socket.assigns.template)

    case Template.validate(template) do
      {:ok, _} ->
        pid = self()

        Task.start(fn ->
          progress_callback = fn step, number ->
            send(pid, {:create_progress, step, number})
          end

          result =
            Docker.create_container(template,
              progress_callback: progress_callback,
              create_paths: true,
              start_after_create: socket.assigns.start_after_create,
              pull_image: socket.assigns.pull_image
            )

          case result do
            {:ok, result} -> send(pid, {:create_complete, result})
            {:error, error} -> send(pid, {:create_failed, error})
          end
        end)

        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:saving, true)}

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

  @impl true
  def handle_event("toggle_template_picker", _params, socket) do
    show = !socket.assigns.show_template_picker

    socket =
      if show and socket.assigns.available_templates == [] do
        assign(socket, :available_templates, Docker.list_templates())
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:show_template_picker, show)
     |> assign(:show_xml_import, false)}
  end

  @impl true
  def handle_event("load_template", %{"name" => name}, socket) do
    case Docker.get_template(name) do
      {:ok, template} ->
        # Clear name for new container
        template = %{template | name: ""}

        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:form, build_form(template))
         |> assign(:show_template_picker, false)
         |> put_flash(:info, "Template loaded - please set a container name")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_template_picker, false)
         |> put_flash(:error, "Failed to load template: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_xml_import", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_xml_import, !socket.assigns.show_xml_import)
     |> assign(:show_template_picker, false)
     |> assign(:show_xml_preview, false)
     |> assign(:xml_input, "")}
  end

  @impl true
  def handle_event("toggle_xml_preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_xml_preview, !socket.assigns.show_xml_preview)
     |> assign(:show_template_picker, false)
     |> assign(:show_xml_import, false)}
  end

  @impl true
  def handle_event("update_xml_input", %{"xml" => xml}, socket) do
    {:noreply, assign(socket, :xml_input, xml)}
  end

  @impl true
  def handle_event("import_xml", _params, socket) do
    xml = socket.assigns.xml_input

    if String.trim(xml) == "" do
      {:noreply, put_flash(socket, :error, "Please paste an XML template")}
    else
      case Template.from_xml(xml) do
        {:ok, template} ->
          # Clear name so user must provide a new one
          template = %{template | name: ""}

          {:noreply,
           socket
           |> assign(:template, template)
           |> assign(:form, build_form(template))
           |> assign(:show_xml_import, false)
           |> assign(:xml_input, "")
           |> put_flash(:info, "Template imported - please set a container name")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to parse XML: #{format_xml_error(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("dismiss_template_error", _params, socket) do
    {:noreply, assign(socket, :template_load_error, nil)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6 max-w-4xl">
      <.header>
        Add Container
        <:subtitle>Create a new Docker container</:subtitle>
        <:actions>
          <.link navigate={~p"/docker"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
          </.link>
        </:actions>
      </.header>

      <div :if={@template_load_error} class="alert alert-warning mb-4">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>{@template_load_error}</span>
        <button type="button" class="btn btn-sm btn-ghost" phx-click="dismiss_template_error">
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <div :if={@loading_template} class="flex items-center justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
        <span class="ml-2">Loading template...</span>
      </div>

      <div :if={!@loading_template} class="mb-4 flex gap-2 flex-wrap">
        <button
          type="button"
          class="btn btn-sm btn-outline"
          phx-click="toggle_template_picker"
        >
          <.icon name="hero-document-text" class="w-4 h-4" />
          {if @show_template_picker, do: "Hide Templates", else: "Load Template"}
        </button>

        <button
          type="button"
          class="btn btn-sm btn-outline"
          phx-click="toggle_xml_import"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
          {if @show_xml_import, do: "Hide Import", else: "Import XML"}
        </button>

        <button
          type="button"
          class="btn btn-sm btn-outline"
          phx-click="toggle_xml_preview"
        >
          <.icon name="hero-code-bracket" class="w-4 h-4" />
          {if @show_xml_preview, do: "Hide Preview", else: "Preview XML"}
        </button>
      </div>

      <div :if={@show_template_picker} class="mb-4 p-4 bg-base-200 rounded-lg">
        <h3 class="font-semibold mb-2">Available Templates</h3>
        <div :if={@available_templates == []} class="text-base-content/60">
          No templates found
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2">
          <button
            :for={{name, _path} <- @available_templates}
            type="button"
            class="btn btn-sm btn-ghost justify-start"
            phx-click="load_template"
            phx-value-name={name}
          >
            <.icon name="hero-document" class="w-4 h-4" />
            {name}
          </button>
        </div>
      </div>

      <form :if={@show_xml_import} class="mb-4 p-4 bg-base-200 rounded-lg" phx-change="update_xml_input" phx-submit="import_xml">
        <h3 class="font-semibold mb-2">Import XML Template</h3>
        <p class="text-sm text-base-content/60 mb-3">
          Paste an XML template below to pre-fill the form.
        </p>
        <textarea
          class="textarea textarea-bordered w-full h-48 font-mono text-xs"
          placeholder={"<?xml version=\"1.0\"?>\n<Container version=\"2\">\n  <Name>my-container</Name>\n  <Repository>nginx:latest</Repository>\n  ...\n</Container>"}
          name="xml"
        >{@xml_input}</textarea>
        <div class="flex justify-end gap-2 mt-3">
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="toggle_xml_import"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="btn btn-sm btn-primary"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Import
          </button>
        </div>
      </form>

      <div :if={@show_xml_preview} class="mb-4 p-4 bg-base-200 rounded-lg">
        <div class="flex items-center justify-between mb-2">
          <h3 class="font-semibold">XML Preview</h3>
          <.copy_button text={Template.to_xml(@template)} class="btn-sm" />
        </div>
        <p class="text-sm text-base-content/60 mb-3">
          This is the XML template that will be saved. You can copy and share this with others.
        </p>
        <pre class="bg-base-300 p-3 rounded text-xs font-mono overflow-x-auto max-h-96 overflow-y-auto"><code>{Template.to_xml(@template)}</code></pre>
      </div>

      <.form
        :if={!@loading_template}
        for={@form}
        phx-change="validate"
        phx-submit="create"
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

        <div class="divider"></div>

        <div class="form-control">
          <label class="label cursor-pointer justify-start gap-4">
            <input
              type="checkbox"
              class="checkbox"
              checked={@start_after_create}
              phx-click="toggle_start_after"
            />
            <span class="label-text">Start container after creation</span>
          </label>
        </div>

        <div class="form-control">
          <label class="label cursor-pointer justify-start gap-4">
            <input
              type="checkbox"
              class="checkbox"
              checked={@pull_image}
              phx-click="toggle_pull_image"
            />
            <span class="label-text">Pull image before creation</span>
          </label>
        </div>

        <.create_actions saving={@saving} cancel_path={~p"/docker"} />
      </.form>

      <.create_progress
        step={@create_step}
        step_number={@create_step_number}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  attr :saving, :boolean, default: false
  attr :cancel_path, :string, required: true

  defp create_actions(assigns) do
    ~H"""
    <div class="flex justify-end gap-2 pt-4">
      <.link navigate={@cancel_path} class="btn btn-ghost">
        Cancel
      </.link>
      <button type="submit" class="btn btn-primary" disabled={@saving}>
        <span class="loading loading-spinner loading-sm" :if={@saving}></span>
        <span :if={!@saving}>Create Container</span>
        <span :if={@saving}>Creating...</span>
      </button>
    </div>
    """
  end

  attr :step, :atom, default: nil
  attr :step_number, :integer, default: 0
  attr :total_steps, :integer, default: 6

  defp create_progress(assigns) do
    ~H"""
    <div :if={@step} class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div class="bg-base-100 rounded-lg p-6 w-96 shadow-xl">
        <h3 class="font-semibold mb-4">Creating Container</h3>
        <progress class="progress progress-primary w-full mb-2" value={@step_number} max={@total_steps}>
        </progress>
        <p class="text-sm text-base-content/70">{create_step_label(@step)}</p>
      </div>
    </div>
    """
  end

  defp create_step_label(:validating), do: "Validating configuration..."
  defp create_step_label(:saving_template), do: "Saving template..."
  defp create_step_label(:pulling_image), do: "Pulling image..."
  defp create_step_label(:creating_container), do: "Creating container..."
  defp create_step_label(:starting_container), do: "Starting container..."
  defp create_step_label(:done), do: "Done!"
  defp create_step_label(_), do: "Processing..."

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_form(template) do
    to_form(%{
      "name" => template.name || "",
      "repository" => template.repository || "",
      "registry" => template.registry || "",
      "network" => template.network || "bridge",
      "my_ip" => template.my_ip || "",
      "shell" => template.shell || "sh",
      "privileged" => template.privileged || false,
      "web_ui" => template.web_ui || "",
      "icon" => template.icon || "",
      "overview" => template.overview || "",
      "cpuset" => template.cpuset || "",
      "extra_params" => template.extra_params || "",
      "post_args" => template.post_args || ""
    })
  end

  defp params_to_template(params, existing_template) do
    configs = parse_configs_from_params(params)
    tailscale = parse_tailscale_from_params(params, existing_template.tailscale)

    %Template{
      name: params["name"] || "",
      repository: params["repository"] || "",
      registry: nilify(params["registry"]),
      network: params["network"] || "bridge",
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
      date_installed: nil,
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

  defp format_xml_error({:parse_error, message}) when is_binary(message) do
    message
  end

  defp format_xml_error(reason), do: inspect(reason)
end
