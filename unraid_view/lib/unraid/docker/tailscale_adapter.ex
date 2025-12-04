defmodule Unraid.Docker.TailscaleAdapter do
  @moduledoc """
  Builds Tailscale-specific docker arguments.

  Handles entrypoint override, hook mount, environment variables,
  and capability/device requirements for Tailscale-enabled containers.

  This module mirrors the Tailscale command building logic from
  the webgui PHP implementation (Helpers.php lines 352-422).
  """

  @hook_path "/usr/local/share/docker/tailscale_container_hook"
  @hook_mount_target "/opt/unraid/tailscale"

  @doc """
  Build all Tailscale-related docker arguments from a tailscale config.

  Returns a list of argument strings to be included in the docker create command.
  """
  def build_args(nil), do: []

  def build_args(%{enabled: false}), do: []

  def build_args(%{enabled: true} = config) do
    []
    |> add_entrypoint()
    |> add_hook_mount()
    |> add_hostname(config)
    |> add_ssh(config)
    |> add_daemon_params(config)
    |> add_extra_params(config)
    |> add_state_dir(config)
    |> add_userspace_networking(config)
    |> add_exit_node_or_capabilities(config)
    |> add_serve_funnel(config)
    |> add_serve_port(config)
    |> add_serve_target(config)
    |> add_serve_local_path(config)
    |> add_serve_protocol(config)
    |> add_serve_protocol_port(config)
    |> add_serve_path(config)
    |> add_troubleshooting(config)
    |> add_routes(config)
    |> add_accept_routes(config)
    |> Enum.reverse()
  end

  @doc """
  Build the hostname label argument.

  This label is used by the UI to identify Tailscale-enabled containers.
  """
  def build_hostname_label(nil), do: nil
  def build_hostname_label(%{enabled: false}), do: nil

  def build_hostname_label(%{enabled: true, hostname: hostname}) when is_binary(hostname) and hostname != "" do
    "-l net.unraid.docker.tailscale.hostname=#{shell_escape(hostname)}"
  end

  def build_hostname_label(_), do: nil

  @doc """
  Build the Tailscale WebUI label argument.
  """
  def build_webui_label(nil), do: nil
  def build_webui_label(%{enabled: false}), do: nil

  def build_webui_label(%{enabled: true, web_ui: web_ui}) when is_binary(web_ui) and web_ui != "" do
    "-l net.unraid.docker.tailscale.webui=#{shell_escape(web_ui)}"
  end

  def build_webui_label(_), do: nil

  @doc """
  Check if this config requires capabilities and device access.

  Returns true for:
  - Exit node containers
  - Containers with userspace_networking disabled
  """
  def requires_capabilities?(%{is_exit_node: true}), do: true

  def requires_capabilities?(%{userspace_networking: usn}) when usn in ["false", false], do: true

  def requires_capabilities?(_), do: false

  @doc """
  Process post_args for Tailscale containers.

  When Tailscale is enabled, the original PostArgs need to be passed
  as ORG_POSTARGS environment variable.

  Returns {tailscale_env_args, modified_post_args}
  """
  def process_post_args(nil, _config), do: {[], nil}
  def process_post_args("", _config), do: {[], nil}
  def process_post_args(post_args, nil), do: {[], post_args}
  def process_post_args(post_args, %{enabled: false}), do: {[], post_args}

  def process_post_args(post_args, %{enabled: true}) when is_binary(post_args) do
    case String.split(post_args, ";", parts: 2) do
      [before_semicolon, after_semicolon] when before_semicolon != "" ->
        env_arg = "-e ORG_POSTARGS=#{shell_escape(before_semicolon)}"
        {[env_arg], ";" <> after_semicolon}

      [single_part] when single_part != "" ->
        env_arg = "-e ORG_POSTARGS=#{shell_escape(single_part)}"
        {[env_arg], ""}

      _ ->
        {[], post_args}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Builders
  # ---------------------------------------------------------------------------

  defp add_entrypoint(args) do
    ["--entrypoint='#{@hook_mount_target}'" | args]
  end

  defp add_hook_mount(args) do
    ["-v '#{@hook_path}':'#{@hook_mount_target}'" | args]
  end

  defp add_hostname(args, %{hostname: hostname}) when is_binary(hostname) and hostname != "" do
    ["-e TAILSCALE_HOSTNAME=#{shell_escape(hostname)}" | args]
  end

  defp add_hostname(args, _), do: args

  defp add_ssh(args, %{ssh: ssh}) when is_binary(ssh) and ssh != "" do
    ["-e TAILSCALE_USE_SSH=#{shell_escape(ssh)}" | args]
  end

  defp add_ssh(args, _), do: args

  defp add_daemon_params(args, %{daemon_params: params}) when is_binary(params) and params != "" do
    ["-e TAILSCALED_PARAMS=#{shell_escape(params)}" | args]
  end

  defp add_daemon_params(args, _), do: args

  defp add_extra_params(args, %{extra_params: params}) when is_binary(params) and params != "" do
    ["-e TAILSCALE_PARAMS=#{shell_escape(params)}" | args]
  end

  defp add_extra_params(args, _), do: args

  defp add_state_dir(args, %{state_dir: dir}) when is_binary(dir) and dir != "" do
    ["-e TAILSCALE_STATE_DIR=#{shell_escape(dir)}" | args]
  end

  defp add_state_dir(args, _), do: args

  defp add_userspace_networking(args, %{userspace_networking: usn}) when is_binary(usn) and usn != "" do
    ["-e TAILSCALE_USERSPACE_NETWORKING=#{shell_escape(usn)}" | args]
  end

  defp add_userspace_networking(args, _), do: args

  defp add_exit_node_or_capabilities(args, config) do
    cond do
      config.is_exit_node == true ->
        args
        |> add_tun_device()
        |> add_net_admin_cap()
        |> then(&["-e TAILSCALE_EXIT_NODE=true" | &1])

      config.userspace_networking in ["false", false] ->
        args
        |> add_tun_device()
        |> add_net_admin_cap()
        |> add_lan_access(config)
        |> add_exit_node_ip(config)

      true ->
        args
    end
  end

  defp add_tun_device(args) do
    ["--device='/dev/net/tun'" | args]
  end

  defp add_net_admin_cap(args) do
    ["--cap-add=NET_ADMIN" | args]
  end

  defp add_lan_access(args, %{lan_access: lan}) when is_binary(lan) and lan != "" do
    ["-e TAILSCALE_ALLOW_LAN_ACCESS=#{shell_escape(lan)}" | args]
  end

  defp add_lan_access(args, _), do: args

  defp add_exit_node_ip(args, %{exit_node_ip: ip}) when is_binary(ip) and ip != "" do
    ["-e TAILSCALE_EXIT_NODE_IP=#{shell_escape(ip)}" | args]
  end

  defp add_exit_node_ip(args, _), do: args

  defp add_serve_funnel(args, %{serve: "funnel"}) do
    ["-e TAILSCALE_FUNNEL=true" | args]
  end

  defp add_serve_funnel(args, _), do: args

  defp add_serve_port(args, %{serve_port: port}) when is_binary(port) and port != "" do
    ["-e TAILSCALE_SERVE_PORT=#{shell_escape(port)}" | args]
  end

  defp add_serve_port(args, _), do: args

  defp add_serve_target(args, %{serve_target: target}) when is_binary(target) and target != "" do
    ["-e TAILSCALE_SERVE_TARGET=#{shell_escape(target)}" | args]
  end

  defp add_serve_target(args, _), do: args

  defp add_serve_local_path(args, %{serve_local_path: path}) when is_binary(path) and path != "" do
    ["-e TAILSCALE_SERVE_LOCALPATH=#{shell_escape(path)}" | args]
  end

  defp add_serve_local_path(args, _), do: args

  defp add_serve_protocol(args, %{serve_protocol: proto}) when is_binary(proto) and proto != "" do
    ["-e TAILSCALE_SERVE_PROTOCOL=#{shell_escape(proto)}" | args]
  end

  defp add_serve_protocol(args, _), do: args

  defp add_serve_protocol_port(args, %{serve_protocol_port: port}) when is_binary(port) and port != "" do
    ["-e TAILSCALE_SERVE_PROTOCOL_PORT=#{shell_escape(port)}" | args]
  end

  defp add_serve_protocol_port(args, _), do: args

  defp add_serve_path(args, %{serve_path: path}) when is_binary(path) and path != "" do
    ["-e TAILSCALE_SERVE_PATH=#{shell_escape(path)}" | args]
  end

  defp add_serve_path(args, _), do: args

  defp add_troubleshooting(args, %{troubleshooting: true}) do
    ["-e TAILSCALE_TROUBLESHOOTING=true" | args]
  end

  defp add_troubleshooting(args, _), do: args

  defp add_routes(args, %{routes: routes}) when is_binary(routes) and routes != "" do
    ["-e TAILSCALE_ADVERTISE_ROUTES=#{shell_escape(routes)}" | args]
  end

  defp add_routes(args, _), do: args

  defp add_accept_routes(args, %{accept_routes: true}) do
    ["-e TAILSCALE_ACCEPT_ROUTES=true" | args]
  end

  defp add_accept_routes(args, _), do: args

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp shell_escape(value) when is_binary(value) do
    # Simple shell escaping - wrap in single quotes and escape any single quotes
    escaped = String.replace(value, "'", "'\\''")
    "'#{escaped}'"
  end

  defp shell_escape(value), do: shell_escape(to_string(value))
end
