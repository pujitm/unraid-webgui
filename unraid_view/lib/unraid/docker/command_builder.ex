defmodule Unraid.Docker.CommandBuilder do
  @moduledoc """
  Builds docker create commands from Template structs.

  This is the Elixir equivalent of `xmlToCommand()` from the PHP codebase
  (Helpers.php lines 321-484).

  The command builder produces output compatible with the webgui docker script,
  maintaining backwards compatibility with existing container management.
  """

  alias Unraid.Docker.{Template, TailscaleAdapter}

  @type command_result :: %{
          command: String.t(),
          args: [String.t()],
          name: String.t(),
          repository: String.t()
        }

  @doc """
  Build the full docker create command from a template.

  Returns `{:ok, command_result}` or `{:error, reason}`.

  ## Options
    - `:create_paths` - Create host paths if they don't exist (default: false)
    - `:network_drivers` - Map of network name to driver type for port handling
    - `:timezone` - Timezone string (default: "America/Los_Angeles")
    - `:hostname` - Host server name (default: "Tower")
    - `:pid_limit` - Container PID limit (default: 2048)
  """
  def build_create_command(%Template{} = template, opts \\ []) do
    case Template.validate(template) do
      {:ok, _} ->
        args = build_all_args(template, opts)
        command = join_command(args)

        {:ok,
         %{
           command: command,
           args: args,
           name: template.name,
           repository: template.repository
         }}

      {:error, errors} ->
        {:error, {:validation_failed, errors}}
    end
  end

  @doc """
  Build the docker create command as a list of argument strings.

  Useful when you need to manipulate the arguments before joining.
  """
  def build_args(%Template{} = template, opts \\ []) do
    build_all_args(template, opts)
  end

  # ---------------------------------------------------------------------------
  # Command Building
  # ---------------------------------------------------------------------------

  defp build_all_args(template, opts) do
    timezone = Keyword.get(opts, :timezone, "America/Los_Angeles")
    hostname = Keyword.get(opts, :hostname, "Tower")
    pid_limit = Keyword.get(opts, :pid_limit, 2048)
    network_drivers = Keyword.get(opts, :network_drivers, %{})

    # Process post_args for Tailscale
    {ts_postargs_env, modified_post_args} =
      TailscaleAdapter.process_post_args(template.post_args, template.tailscale)

    []
    |> add_arg("docker create")
    |> add_name(template)
    |> add_tailscale_entrypoint(template)
    |> add_network(template)
    |> add_ip(template)
    |> add_cpuset(template)
    |> add_pid_limit(template, pid_limit)
    |> add_privileged(template)
    |> add_env_vars(template, timezone, hostname)
    |> add_tailscale_env(template)
    |> add_args(ts_postargs_env)
    |> add_labels(template)
    |> add_tailscale_labels(template)
    |> add_ports(template, network_drivers)
    |> add_volumes(template, opts)
    |> add_tailscale_hook(template)
    |> add_tailscale_caps(template)
    |> add_devices(template)
    |> add_extra_params(template)
    |> add_repository(template)
    |> add_post_args(modified_post_args)
    |> Enum.reverse()
  end

  defp join_command(args) do
    args
    |> Enum.join(" ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Individual Argument Builders
  # ---------------------------------------------------------------------------

  defp add_arg(args, arg), do: [arg | args]

  defp add_args(args, new_args) when is_list(new_args) do
    Enum.reduce(new_args, args, fn arg, acc -> [arg | acc] end)
  end

  defp add_name(args, %{name: name}) when is_binary(name) and name != "" do
    ["--name=#{shell_escape(name)}" | args]
  end

  defp add_name(args, _), do: args

  defp add_tailscale_entrypoint(args, %{tailscale: %{enabled: true}}) do
    # Entrypoint is handled by TailscaleAdapter.build_args
    args
  end

  defp add_tailscale_entrypoint(args, _), do: args

  defp add_network(args, %{network: network, extra_params: extra}) do
    # Don't add network if already specified in extra params
    if extra && String.match?(extra, ~r/--net(work)?=/) do
      args
    else
      network_arg = normalize_network(network)
      ["--net=#{shell_escape(network_arg)}" | args]
    end
  end

  defp normalize_network(network) do
    if String.starts_with?(network, "container:") do
      network
    else
      String.downcase(network)
    end
  end

  defp add_ip(args, %{my_ip: my_ip}) when is_binary(my_ip) and my_ip != "" do
    # my_ip can contain multiple IPs separated by comma or space
    my_ip
    |> String.replace(",", " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(args, fn ip, acc ->
      if String.contains?(ip, ":") do
        ["--ip6=#{shell_escape(ip)}" | acc]
      else
        ["--ip=#{shell_escape(ip)}" | acc]
      end
    end)
  end

  defp add_ip(args, _), do: args

  defp add_cpuset(args, %{cpuset: cpuset}) when is_binary(cpuset) and cpuset != "" do
    ["--cpuset-cpus=#{shell_escape(cpuset)}" | args]
  end

  defp add_cpuset(args, _), do: args

  defp add_pid_limit(args, %{extra_params: extra}, default_limit) do
    # Don't add if already specified in extra params
    if extra && String.match?(extra, ~r/--pids-limit\s+\d+/) do
      args
    else
      ["--pids-limit #{default_limit}" | args]
    end
  end

  defp add_privileged(args, %{privileged: true}) do
    ["--privileged=true" | args]
  end

  defp add_privileged(args, _), do: args

  defp add_env_vars(args, template, timezone, hostname) do
    # Add standard environment variables
    standard_vars = [
      ~s(-e TZ="#{timezone}"),
      ~s(-e HOST_OS="Unraid"),
      ~s(-e HOST_HOSTNAME="#{hostname}"),
      ~s(-e HOST_CONTAINERNAME="#{template.name}")
    ]

    # Add user-defined variables from config
    user_vars =
      template
      |> Template.variables()
      |> Enum.map(fn config ->
        value = if config.value != "", do: config.value, else: config.default
        "-e #{shell_escape(config.target)}=#{shell_escape(value)}"
      end)

    Enum.reduce(standard_vars ++ user_vars, args, fn var, acc -> [var | acc] end)
  end

  defp add_tailscale_env(args, %{tailscale: ts}) when is_map(ts) and ts.enabled == true do
    ts_args = TailscaleAdapter.build_args(ts)
    Enum.reduce(ts_args, args, fn arg, acc -> [arg | acc] end)
  end

  defp add_tailscale_env(args, _), do: args

  defp add_labels(args, template) do
    # Standard labels
    standard_labels = [
      "-l net.unraid.docker.managed=dockerman"
    ]

    # WebUI label
    webui_label =
      if template.web_ui && template.web_ui != "" do
        ["-l net.unraid.docker.webui=#{shell_escape(template.web_ui)}"]
      else
        []
      end

    # Icon label
    icon_label =
      if template.icon && template.icon != "" do
        ["-l net.unraid.docker.icon=#{shell_escape(template.icon)}"]
      else
        []
      end

    # User-defined labels from config
    user_labels =
      template
      |> Template.labels()
      |> Enum.map(fn config ->
        value = if config.value != "", do: config.value, else: config.default
        "-l #{shell_escape(config.target)}=#{shell_escape(value)}"
      end)

    all_labels = standard_labels ++ webui_label ++ icon_label ++ user_labels
    Enum.reduce(all_labels, args, fn label, acc -> [label | acc] end)
  end

  defp add_tailscale_labels(args, %{tailscale: ts}) when is_map(ts) and ts.enabled == true do
    labels =
      [
        TailscaleAdapter.build_hostname_label(ts),
        TailscaleAdapter.build_webui_label(ts)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce(labels, args, fn label, acc -> [label | acc] end)
  end

  defp add_tailscale_labels(args, _), do: args

  defp add_ports(args, template, network_drivers) do
    network_driver = Map.get(network_drivers, template.network, "bridge")

    ports =
      template
      |> Template.ports()
      |> Enum.flat_map(fn config ->
        value = if config.value != "", do: config.value, else: config.default
        mode = if config.mode != "", do: config.mode, else: "tcp"
        target = config.target

        case network_driver do
          driver when driver in ["host", "macvlan", "ipvlan"] ->
            # Export ports as environment variables
            var_name = String.upcase("#{mode}_PORT_#{target}")
            ["-e #{shell_escape(var_name)}=#{shell_escape(value)}"]

          "bridge" ->
            # Export as port mapping
            ["-p #{shell_escape("#{value}:#{target}/#{mode}")}"]

          "none" ->
            # No port export
            []

          _ ->
            # Default to bridge behavior
            ["-p #{shell_escape("#{value}:#{target}/#{mode}")}"]
        end
      end)

    Enum.reduce(ports, args, fn port, acc -> [port | acc] end)
  end

  defp add_volumes(args, template, opts) do
    create_paths = Keyword.get(opts, :create_paths, false)

    volumes =
      template
      |> Template.paths()
      |> Enum.flat_map(fn config ->
        value = if config.value != "", do: config.value, else: config.default
        target = config.target
        mode = if config.mode != "", do: config.mode, else: "rw"

        if value != "" and target != "" do
          # Optionally create the host path
          if create_paths and not File.exists?(value) do
            File.mkdir_p!(value)
          end

          ["-v #{shell_escape(value)}:#{shell_escape(target)}:#{shell_escape(mode)}"]
        else
          []
        end
      end)

    Enum.reduce(volumes, args, fn vol, acc -> [vol | acc] end)
  end

  defp add_tailscale_hook(args, %{tailscale: %{enabled: true}}) do
    # Hook mount is included in TailscaleAdapter.build_args
    args
  end

  defp add_tailscale_hook(args, _), do: args

  defp add_tailscale_caps(args, %{tailscale: ts, extra_params: extra}) when is_map(ts) and ts.enabled == true do
    if TailscaleAdapter.requires_capabilities?(ts) do
      # Add tun device if not in extra params
      args =
        if extra && String.match?(extra, ~r/--d(evice)?[= ](\'?\/dev\/net\/tun\'?)/) do
          args
        else
          ["--device='/dev/net/tun'" | args]
        end

      # Add NET_ADMIN capability if not in extra params
      args =
        if extra && String.match?(extra, ~r/--cap-add=NET_ADMIN/) do
          args
        else
          ["--cap-add=NET_ADMIN" | args]
        end

      args
    else
      args
    end
  end

  defp add_tailscale_caps(args, _), do: args

  defp add_devices(args, template) do
    devices =
      template
      |> Template.devices()
      |> Enum.map(fn config ->
        value = if config.value != "", do: config.value, else: config.default
        "--device=#{shell_escape(value)}"
      end)

    Enum.reduce(devices, args, fn device, acc -> [device | acc] end)
  end

  defp add_extra_params(args, %{extra_params: extra}) when is_binary(extra) and extra != "" do
    [extra | args]
  end

  defp add_extra_params(args, _), do: args

  defp add_repository(args, %{repository: repo}) when is_binary(repo) and repo != "" do
    [shell_escape(repo) | args]
  end

  defp add_repository(args, _), do: args

  defp add_post_args(args, post_args) when is_binary(post_args) and post_args != "" do
    [post_args | args]
  end

  defp add_post_args(args, _), do: args

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp shell_escape(value) when is_binary(value) do
    # Simple shell escaping - wrap in single quotes and escape any single quotes
    if String.contains?(value, ["'", " ", "\"", "$", "`", "\\", "\n"]) do
      escaped = String.replace(value, "'", "'\\''")
      "'#{escaped}'"
    else
      value
    end
  end

  defp shell_escape(value), do: shell_escape(to_string(value))
end
