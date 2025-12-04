defmodule Unraid.Docker.Container do
  @moduledoc """
  Struct representing a Docker container with all relevant metadata.

  This struct normalizes the Docker API response into a consistent format
  for use in LiveViews and other UI components.
  """

  @type state :: :running | :paused | :stopped | :restarting | :dead | :created | :removing

  @type port_mapping :: %{
          private: non_neg_integer(),
          public: non_neg_integer() | nil,
          type: String.t(),
          ip: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          image: String.t(),
          image_id: String.t(),
          status: String.t(),
          state: state(),
          created: DateTime.t() | nil,
          ports: [port_mapping()],
          networks: %{String.t() => %{ip: String.t()}},
          volumes: [String.t()],
          network_mode: String.t(),
          cpu_percent: float() | nil,
          memory_usage: String.t() | nil,
          memory_percent: float() | nil,
          icon: String.t() | nil,
          web_ui: String.t() | nil,
          shell: String.t() | nil,
          manager: String.t() | nil,
          compose_project: String.t() | nil,
          labels: %{String.t() => String.t()}
        }

  defstruct [
    :id,
    :name,
    :image,
    :image_id,
    :status,
    :state,
    :created,
    :ports,
    :networks,
    :volumes,
    :network_mode,
    :cpu_percent,
    :memory_usage,
    :memory_percent,
    :icon,
    :web_ui,
    :shell,
    :manager,
    :compose_project,
    :labels
  ]

  @doc """
  Creates a Container struct from Docker API response data.

  Accepts the response from `container_list` or `container_inspect` endpoints.
  Works with both plain maps and DockerEngineAPI.Model.ContainerSummary structs.
  """
  def from_api(%DockerEngineAPI.Model.ContainerSummary{} = data) do
    labels = data."Labels" || %{}

    %__MODULE__{
      id: short_id(data."Id"),
      name: normalize_name(data."Names"),
      image: data."Image",
      image_id: short_id(data."ImageID"),
      status: data."Status",
      state: parse_state(data."State"),
      created: parse_created(data."Created"),
      ports: parse_ports(data."Ports" || []),
      networks: parse_networks(data."NetworkSettings"),
      volumes: parse_volumes(data."Mounts" || []),
      network_mode: parse_network_mode(data."HostConfig"),
      cpu_percent: nil,
      memory_usage: nil,
      memory_percent: nil,
      icon: labels["net.unraid.docker.icon"],
      web_ui: labels["net.unraid.docker.webui"],
      shell: labels["net.unraid.docker.shell"] || "sh",
      manager: parse_manager(labels),
      compose_project: labels["com.docker.compose.project"],
      labels: labels
    }
  end

  def from_api(data) when is_map(data) do
    labels = data["Labels"] || %{}

    %__MODULE__{
      id: short_id(data["Id"]),
      name: normalize_name(data["Names"] || data["Name"]),
      image: data["Image"],
      image_id: short_id(data["ImageID"] || data["Image"]),
      status: data["Status"] || state_to_status(data["State"]),
      state: parse_state(data["State"]),
      created: parse_created(data["Created"]),
      ports: parse_ports(data["Ports"] || []),
      networks: parse_networks(data["NetworkSettings"]),
      volumes: parse_volumes(data["Mounts"] || []),
      network_mode: parse_network_mode(data["HostConfig"]),
      cpu_percent: nil,
      memory_usage: nil,
      memory_percent: nil,
      icon: labels["net.unraid.docker.icon"],
      web_ui: labels["net.unraid.docker.webui"],
      shell: labels["net.unraid.docker.shell"] || "sh",
      manager: parse_manager(labels),
      compose_project: labels["com.docker.compose.project"],
      labels: labels
    }
  end

  @doc """
  Updates a container with stats data.
  """
  def with_stats(%__MODULE__{} = container, stats) when is_map(stats) do
    %{
      container
      | cpu_percent: stats[:cpu_percent] || stats["cpu_percent"],
        memory_usage: stats[:memory_usage] || stats["memory_usage"],
        memory_percent: stats[:memory_percent] || stats["memory_percent"]
    }
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp short_id(nil), do: nil
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)

  defp normalize_name(nil), do: "unknown"
  defp normalize_name([name | _]) when is_binary(name), do: String.trim_leading(name, "/")
  defp normalize_name(name) when is_binary(name), do: String.trim_leading(name, "/")
  defp normalize_name(_), do: "unknown"

  defp parse_state(%{"Status" => status}) when is_binary(status) do
    parse_state_string(status)
  end

  defp parse_state(state) when is_binary(state) do
    parse_state_string(state)
  end

  defp parse_state(_), do: :stopped

  defp parse_state_string(state) do
    case String.downcase(state) do
      "running" -> :running
      "paused" -> :paused
      "exited" -> :stopped
      "dead" -> :dead
      "restarting" -> :restarting
      "created" -> :created
      "removing" -> :removing
      _ -> :stopped
    end
  end

  defp state_to_status(%{"Status" => status}), do: status
  defp state_to_status(_), do: "Unknown"

  defp parse_created(timestamp) when is_integer(timestamp) do
    DateTime.from_unix(timestamp)
    |> case do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_created(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_created(_), do: nil

  defp parse_ports(ports) when is_list(ports) do
    Enum.map(ports, fn port ->
      %{
        private: get_field(port, :PrivatePort, "PrivatePort"),
        public: get_field(port, :PublicPort, "PublicPort"),
        type: get_field(port, :Type, "Type") || "tcp",
        ip: get_field(port, :IP, "IP")
      }
    end)
  end

  defp parse_ports(_), do: []

  # Handle DockerEngineAPI.Model.ContainerSummaryNetworkSettings struct
  defp parse_networks(%DockerEngineAPI.Model.ContainerSummaryNetworkSettings{} = settings) do
    networks = settings."Networks" || %{}
    parse_networks_map(networks)
  end

  defp parse_networks(%{"Networks" => networks}) when is_map(networks) do
    parse_networks_map(networks)
  end

  defp parse_networks(_), do: %{}

  defp parse_networks_map(networks) when is_map(networks) do
    Map.new(networks, fn {name, config} ->
      ip = get_field(config, :IPAddress, "IPAddress") || ""
      {name, %{ip: ip}}
    end)
  end

  defp parse_volumes(mounts) when is_list(mounts) do
    Enum.map(mounts, fn mount ->
      source = get_field(mount, :Source, "Source") || ""
      dest = get_field(mount, :Destination, "Destination") || ""
      "#{source}:#{dest}"
    end)
  end

  defp parse_volumes(_), do: []

  # Handle DockerEngineAPI.Model.ContainerSummaryHostConfig struct
  defp parse_network_mode(%DockerEngineAPI.Model.ContainerSummaryHostConfig{} = config) do
    config."NetworkMode" || "default"
  end

  defp parse_network_mode(%{"NetworkMode" => mode}) when is_binary(mode), do: mode
  defp parse_network_mode(_), do: "default"

  # Helper to get a field from either a struct or a map
  defp get_field(data, struct_key, _map_key) when is_struct(data) do
    Map.get(data, struct_key)
  end

  defp get_field(data, _struct_key, map_key) when is_map(data) do
    data[map_key]
  end

  defp get_field(_, _, _), do: nil

  defp parse_manager(labels) do
    cond do
      labels["net.unraid.docker.managed"] == "dockerman" -> "dockerman"
      labels["com.docker.compose.project"] != nil -> "composeman"
      true -> nil
    end
  end
end
