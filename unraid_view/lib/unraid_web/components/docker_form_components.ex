defmodule UnraidWeb.DockerFormComponents do
  @moduledoc """
  Form components for Docker container settings editing.

  These components are designed to work with the Template struct
  and provide a clean UI for editing container configurations.
  """

  use Phoenix.Component
  use Gettext, backend: UnraidWeb.Gettext

  import UnraidWeb.CoreComponents

  # ---------------------------------------------------------------------------
  # Section Components
  # ---------------------------------------------------------------------------

  @doc """
  Renders a collapsible section with a header.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :open, :boolean, default: true
  attr :id, :string, required: true

  slot :inner_block, required: true

  def form_section(assigns) do
    ~H"""
    <div class="collapse collapse-arrow bg-base-200 mb-4" id={@id}>
      <input type="checkbox" checked={@open} />
      <div class="collapse-title font-medium">
        <div class="flex items-center gap-2">
          <span>{@title}</span>
          <span :if={@subtitle} class="text-sm text-base-content/60">{@subtitle}</span>
        </div>
      </div>
      <div class="collapse-content">
        <div class="pt-2">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the basic settings section (name, image, network).
  """
  attr :form, :map, required: true
  attr :networks, :list, default: []

  def basic_settings_section(assigns) do
    ~H"""
    <.form_section title="Basic Settings" id="basic-settings">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.input field={@form[:name]} label="Container Name" placeholder="my-container" required />
        <.input field={@form[:repository]} label="Repository" placeholder="nginx:latest" required />
        <.input field={@form[:registry]} label="Registry URL" placeholder="Optional registry URL" />
        <.input
          field={@form[:network]}
          type="select"
          label="Network Mode"
          options={network_options(@networks)}
        />
        <.input field={@form[:my_ip]} label="Fixed IP Address" placeholder="Optional IP address" />
        <.input
          field={@form[:shell]}
          type="select"
          label="Console Shell"
          options={[{"sh", "sh"}, {"bash", "bash"}, {"ash", "ash"}]}
        />
      </div>
      <div class="mt-4">
        <.input field={@form[:privileged]} type="checkbox" label="Privileged Mode" />
      </div>
    </.form_section>
    """
  end

  defp network_options(networks) when is_list(networks) and length(networks) > 0 do
    networks
  end

  defp network_options(_) do
    [
      {"Bridge", "bridge"},
      {"Host", "host"},
      {"None", "none"}
    ]
  end

  @doc """
  Renders the UI/metadata settings section.
  """
  attr :form, :map, required: true

  def ui_settings_section(assigns) do
    ~H"""
    <.form_section title="UI Settings" subtitle="Optional metadata" id="ui-settings" open={false}>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.input field={@form[:web_ui]} label="WebUI URL" placeholder="http://[IP]:[PORT:8080]/" />
        <.input field={@form[:icon]} label="Icon URL" placeholder="https://example.com/icon.png" />
      </div>
      <div class="mt-4">
        <.input field={@form[:overview]} type="textarea" label="Overview" placeholder="Container description" />
      </div>
    </.form_section>
    """
  end

  @doc """
  Renders the advanced settings section (CPU, extra params).
  """
  attr :form, :map, required: true
  attr :available_cpus, :list, default: []

  def advanced_settings_section(assigns) do
    ~H"""
    <.form_section title="Advanced Settings" id="advanced-settings" open={false}>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.input field={@form[:cpuset]} label="CPU Pinning" placeholder="0,1,2-4" />
        <.input field={@form[:extra_params]} label="Extra Parameters" placeholder="--memory=1g" />
        <.input field={@form[:post_args]} label="Post Arguments" placeholder="Arguments after image" />
      </div>
    </.form_section>
    """
  end

  # ---------------------------------------------------------------------------
  # Config Item Sections
  # ---------------------------------------------------------------------------

  @doc """
  Renders the port mappings section.
  """
  attr :configs, :list, required: true
  attr :on_add, :string, default: "add_config"
  attr :on_remove, :string, default: "remove_config"

  def port_mappings_section(assigns) do
    ports = Enum.with_index(assigns.configs) |> Enum.filter(fn {c, _} -> c.type == :port end)
    assigns = assign(assigns, :ports, ports)

    ~H"""
    <.form_section title="Port Mappings" subtitle={"#{length(@ports)} ports"} id="port-mappings">
      <div class="space-y-2">
        <div :for={{config, index} <- @ports} class="flex items-center gap-2">
          <.config_item_row config={config} index={index} type={:port} on_remove={@on_remove} />
        </div>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_add}
          phx-value-type="port"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add Port
        </button>
      </div>
    </.form_section>
    """
  end

  @doc """
  Renders the volume mappings section.
  """
  attr :configs, :list, required: true
  attr :on_add, :string, default: "add_config"
  attr :on_remove, :string, default: "remove_config"

  def volume_mappings_section(assigns) do
    paths = Enum.with_index(assigns.configs) |> Enum.filter(fn {c, _} -> c.type == :path end)
    assigns = assign(assigns, :paths, paths)

    ~H"""
    <.form_section title="Volume Mappings" subtitle={"#{length(@paths)} volumes"} id="volume-mappings">
      <div class="space-y-2">
        <div :for={{config, index} <- @paths} class="flex items-center gap-2">
          <.config_item_row config={config} index={index} type={:path} on_remove={@on_remove} />
        </div>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_add}
          phx-value-type="path"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add Volume
        </button>
      </div>
    </.form_section>
    """
  end

  @doc """
  Renders the environment variables section.
  """
  attr :configs, :list, required: true
  attr :on_add, :string, default: "add_config"
  attr :on_remove, :string, default: "remove_config"

  def environment_section(assigns) do
    variables =
      Enum.with_index(assigns.configs) |> Enum.filter(fn {c, _} -> c.type == :variable end)

    assigns = assign(assigns, :variables, variables)

    ~H"""
    <.form_section
      title="Environment Variables"
      subtitle={"#{length(@variables)} variables"}
      id="environment"
    >
      <div class="space-y-2">
        <div :for={{config, index} <- @variables} class="flex items-center gap-2">
          <.config_item_row config={config} index={index} type={:variable} on_remove={@on_remove} />
        </div>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_add}
          phx-value-type="variable"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add Variable
        </button>
      </div>
    </.form_section>
    """
  end

  @doc """
  Renders the labels section.
  """
  attr :configs, :list, required: true
  attr :on_add, :string, default: "add_config"
  attr :on_remove, :string, default: "remove_config"

  def labels_section(assigns) do
    labels = Enum.with_index(assigns.configs) |> Enum.filter(fn {c, _} -> c.type == :label end)
    assigns = assign(assigns, :labels, labels)

    ~H"""
    <.form_section title="Labels" subtitle={"#{length(@labels)} labels"} id="labels" open={false}>
      <div class="space-y-2">
        <div :for={{config, index} <- @labels} class="flex items-center gap-2">
          <.config_item_row config={config} index={index} type={:label} on_remove={@on_remove} />
        </div>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_add}
          phx-value-type="label"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add Label
        </button>
      </div>
    </.form_section>
    """
  end

  @doc """
  Renders the devices section.
  """
  attr :configs, :list, required: true
  attr :on_add, :string, default: "add_config"
  attr :on_remove, :string, default: "remove_config"

  def devices_section(assigns) do
    devices = Enum.with_index(assigns.configs) |> Enum.filter(fn {c, _} -> c.type == :device end)
    assigns = assign(assigns, :devices, devices)

    ~H"""
    <.form_section title="Devices" subtitle={"#{length(@devices)} devices"} id="devices" open={false}>
      <div class="space-y-2">
        <div :for={{config, index} <- @devices} class="flex items-center gap-2">
          <.config_item_row config={config} index={index} type={:device} on_remove={@on_remove} />
        </div>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_add}
          phx-value-type="device"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add Device
        </button>
      </div>
    </.form_section>
    """
  end

  # ---------------------------------------------------------------------------
  # Config Item Row
  # ---------------------------------------------------------------------------

  @doc """
  Renders a single config item row based on type.
  """
  attr :config, :map, required: true
  attr :index, :integer, required: true
  attr :type, :atom, required: true
  attr :on_remove, :string, default: "remove_config"

  def config_item_row(%{type: :port} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 w-full bg-base-100 p-2 rounded">
      <input
        type="text"
        name={"configs[#{@index}][name]"}
        value={@config.name}
        placeholder="Name"
        class="input input-sm w-32"
      />
      <input
        type="text"
        name={"configs[#{@index}][value]"}
        value={@config.value}
        placeholder="Host Port"
        class="input input-sm w-24"
      />
      <span class="text-base-content/60">:</span>
      <input
        type="text"
        name={"configs[#{@index}][target]"}
        value={@config.target}
        placeholder="Container Port"
        class="input input-sm w-24"
      />
      <select name={"configs[#{@index}][mode]"} class="select select-sm w-20">
        <option value="tcp" selected={@config.mode == "tcp"}>TCP</option>
        <option value="udp" selected={@config.mode == "udp"}>UDP</option>
      </select>
      <input type="hidden" name={"configs[#{@index}][type]"} value="port" />
      <button
        type="button"
        class="btn btn-sm btn-ghost btn-circle"
        phx-click={@on_remove}
        phx-value-index={@index}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  def config_item_row(%{type: :path} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 w-full bg-base-100 p-2 rounded">
      <input
        type="text"
        name={"configs[#{@index}][name]"}
        value={@config.name}
        placeholder="Name"
        class="input input-sm w-32"
      />
      <input
        type="text"
        name={"configs[#{@index}][value]"}
        value={@config.value}
        placeholder="Host Path"
        class="input input-sm flex-1"
      />
      <span class="text-base-content/60">:</span>
      <input
        type="text"
        name={"configs[#{@index}][target]"}
        value={@config.target}
        placeholder="Container Path"
        class="input input-sm flex-1"
      />
      <select name={"configs[#{@index}][mode]"} class="select select-sm w-24">
        <option value="rw" selected={@config.mode == "rw"}>Read/Write</option>
        <option value="ro" selected={@config.mode == "ro"}>Read Only</option>
        <option value="rw,slave" selected={@config.mode == "rw,slave"}>RW Slave</option>
        <option value="rw,shared" selected={@config.mode == "rw,shared"}>RW Shared</option>
      </select>
      <input type="hidden" name={"configs[#{@index}][type]"} value="path" />
      <button
        type="button"
        class="btn btn-sm btn-ghost btn-circle"
        phx-click={@on_remove}
        phx-value-index={@index}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  def config_item_row(%{type: :variable} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 w-full bg-base-100 p-2 rounded">
      <input
        type="text"
        name={"configs[#{@index}][name]"}
        value={@config.name}
        placeholder="Display Name"
        class="input input-sm w-32"
      />
      <input
        type="text"
        name={"configs[#{@index}][target]"}
        value={@config.target}
        placeholder="Variable Name"
        class="input input-sm w-40"
      />
      <span class="text-base-content/60">=</span>
      <input
        type={if @config.mask, do: "password", else: "text"}
        name={"configs[#{@index}][value]"}
        value={@config.value}
        placeholder="Value"
        class="input input-sm flex-1"
      />
      <input type="hidden" name={"configs[#{@index}][type]"} value="variable" />
      <button
        type="button"
        class="btn btn-sm btn-ghost btn-circle"
        phx-click={@on_remove}
        phx-value-index={@index}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  def config_item_row(%{type: :label} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 w-full bg-base-100 p-2 rounded">
      <input
        type="text"
        name={"configs[#{@index}][target]"}
        value={@config.target}
        placeholder="Label Key"
        class="input input-sm flex-1"
      />
      <span class="text-base-content/60">=</span>
      <input
        type="text"
        name={"configs[#{@index}][value]"}
        value={@config.value}
        placeholder="Label Value"
        class="input input-sm flex-1"
      />
      <input type="hidden" name={"configs[#{@index}][type]"} value="label" />
      <button
        type="button"
        class="btn btn-sm btn-ghost btn-circle"
        phx-click={@on_remove}
        phx-value-index={@index}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  def config_item_row(%{type: :device} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 w-full bg-base-100 p-2 rounded">
      <input
        type="text"
        name={"configs[#{@index}][value]"}
        value={@config.value}
        placeholder="Device Path (e.g., /dev/dri)"
        class="input input-sm flex-1"
      />
      <input type="hidden" name={"configs[#{@index}][type]"} value="device" />
      <button
        type="button"
        class="btn btn-sm btn-ghost btn-circle"
        phx-click={@on_remove}
        phx-value-index={@index}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tailscale Section
  # ---------------------------------------------------------------------------

  @doc """
  Renders the Tailscale settings section.
  """
  attr :tailscale, :map, default: nil
  attr :form_name, :string, default: "tailscale"

  def tailscale_section(assigns) do
    ts = assigns.tailscale || %{enabled: false}
    assigns = assign(assigns, :ts, ts)

    ~H"""
    <.form_section title="Tailscale" subtitle={if @ts.enabled, do: "Enabled", else: "Disabled"} id="tailscale" open={@ts.enabled}>
      <div class="space-y-4">
        <label class="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            name={"#{@form_name}[enabled]"}
            value="true"
            checked={@ts.enabled}
            class="checkbox checkbox-sm"
          />
          <span>Enable Tailscale</span>
        </label>

        <div :if={@ts.enabled} class="space-y-4 pl-4 border-l-2 border-primary/20">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <fieldset class="fieldset">
              <label>
                <span class="label">Hostname</span>
                <input
                  type="text"
                  name={"#{@form_name}[hostname]"}
                  value={@ts[:hostname]}
                  placeholder="container-hostname"
                  class="input input-sm w-full"
                />
              </label>
            </fieldset>

            <fieldset class="fieldset">
              <label>
                <span class="label">Serve Mode</span>
                <select name={"#{@form_name}[serve]"} class="select select-sm w-full">
                  <option value="no" selected={@ts[:serve] in [nil, "no", ""]}>Disabled</option>
                  <option value="serve" selected={@ts[:serve] == "serve"}>Serve</option>
                  <option value="funnel" selected={@ts[:serve] == "funnel"}>Funnel</option>
                </select>
              </label>
            </fieldset>
          </div>

          <div class="flex flex-wrap gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name={"#{@form_name}[is_exit_node]"}
                value="true"
                checked={@ts[:is_exit_node] == true}
                class="checkbox checkbox-sm"
              />
              <span>Exit Node</span>
            </label>

            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name={"#{@form_name}[ssh]"}
                value="true"
                checked={@ts[:ssh] == "true"}
                class="checkbox checkbox-sm"
              />
              <span>SSH Access</span>
            </label>

            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name={"#{@form_name}[accept_routes]"}
                value="true"
                checked={@ts[:accept_routes] == true}
                class="checkbox checkbox-sm"
              />
              <span>Accept Routes</span>
            </label>
          </div>

          <div :if={@ts[:serve] in ["serve", "funnel"]} class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <fieldset class="fieldset">
              <label>
                <span class="label">Serve Port</span>
                <input
                  type="text"
                  name={"#{@form_name}[serve_port]"}
                  value={@ts[:serve_port]}
                  placeholder="443"
                  class="input input-sm w-full"
                />
              </label>
            </fieldset>
            <fieldset class="fieldset">
              <label>
                <span class="label">Serve Target</span>
                <input
                  type="text"
                  name={"#{@form_name}[serve_target]"}
                  value={@ts[:serve_target]}
                  placeholder="http://localhost:8080"
                  class="input input-sm w-full"
                />
              </label>
            </fieldset>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <fieldset class="fieldset">
              <label>
                <span class="label">Advertise Routes</span>
                <input
                  type="text"
                  name={"#{@form_name}[routes]"}
                  value={@ts[:routes]}
                  placeholder="192.168.1.0/24"
                  class="input input-sm w-full"
                />
              </label>
            </fieldset>
            <fieldset class="fieldset">
              <label>
                <span class="label">Exit Node IP</span>
                <input
                  type="text"
                  name={"#{@form_name}[exit_node_ip]"}
                  value={@ts[:exit_node_ip]}
                  placeholder="Exit node to use"
                  class="input input-sm w-full"
                />
              </label>
            </fieldset>
          </div>

          <fieldset class="fieldset">
            <label>
              <span class="label">Extra Tailscale Parameters</span>
              <input
                type="text"
                name={"#{@form_name}[extra_params]"}
                value={@ts[:extra_params]}
                placeholder="Additional tailscale up parameters"
                class="input input-sm w-full"
              />
            </label>
          </fieldset>
        </div>
      </div>
    </.form_section>
    """
  end

  # ---------------------------------------------------------------------------
  # Action Buttons
  # ---------------------------------------------------------------------------

  @doc """
  Renders the form action buttons.
  """
  attr :saving, :boolean, default: false
  attr :cancel_path, :string, default: nil

  def form_actions(assigns) do
    ~H"""
    <div class="flex items-center justify-end gap-4 mt-6 pt-4 border-t border-base-300">
      <.link :if={@cancel_path} navigate={@cancel_path} class="btn btn-ghost">
        Cancel
      </.link>
      <button type="submit" class="btn btn-primary" disabled={@saving}>
        <span :if={@saving} class="loading loading-spinner loading-sm"></span>
        <span :if={!@saving}>Save & Apply</span>
        <span :if={@saving}>Applying...</span>
      </button>
    </div>
    """
  end

  @doc """
  Renders an update progress indicator.
  """
  attr :step, :atom, default: nil
  attr :step_number, :integer, default: 0
  attr :total_steps, :integer, default: 9

  def update_progress(assigns) do
    ~H"""
    <div :if={@step} class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div class="bg-base-100 rounded-lg p-6 w-96 shadow-xl">
        <h3 class="font-semibold mb-4">Updating Container</h3>
        <progress class="progress progress-primary w-full mb-2" value={@step_number} max={@total_steps}>
        </progress>
        <p class="text-sm text-base-content/70">{step_label(@step)}</p>
      </div>
    </div>
    """
  end

  defp step_label(:validating), do: "Validating configuration..."
  defp step_label(:backing_up), do: "Creating backup..."
  defp step_label(:saving_template), do: "Saving template..."
  defp step_label(:stopping_container), do: "Stopping container..."
  defp step_label(:removing_container), do: "Removing old container..."
  defp step_label(:pulling_image), do: "Pulling image..."
  defp step_label(:creating_container), do: "Creating new container..."
  defp step_label(:starting_container), do: "Starting container..."
  defp step_label(:done), do: "Done!"
  defp step_label(_), do: "Processing..."
end
