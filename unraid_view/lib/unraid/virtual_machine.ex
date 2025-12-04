defmodule Unraid.VirtualMachine do
  @moduledoc """
  Context for managing virtual machines via libvirt/virsh.

  Provides functions to list, query, and control VMs through the virsh CLI.
  """

  defstruct [
    :id,
    :name,
    :description,
    :state,
    :cpu_cores,
    :memory_mb,
    :disk_count,
    :disk_total_bytes,
    :ip_address,
    :autostart,
    :graphics_driver,
    :storage_devices,
    :network_interfaces,
    :children
  ]

  @type state :: :running | :stopped | :paused | :suspended | :crashed | :unknown

  @type storage_device :: %{
          path: String.t(),
          serial: String.t() | nil,
          bus: String.t(),
          capacity_bytes: non_neg_integer() | nil,
          allocated_bytes: non_neg_integer() | nil,
          boot_order: non_neg_integer() | nil
        }

  @type network_interface :: %{
          mac: String.t(),
          bridge: String.t() | nil,
          type: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          state: state(),
          cpu_cores: non_neg_integer() | nil,
          memory_mb: non_neg_integer() | nil,
          disk_count: non_neg_integer(),
          disk_total_bytes: non_neg_integer(),
          ip_address: String.t() | nil,
          autostart: boolean(),
          graphics_driver: String.t() | nil,
          storage_devices: [storage_device()],
          network_interfaces: [network_interface()],
          children: [t()] | nil
        }

  @doc """
  Lists all virtual machines with full details.
  """
  @spec list_all() :: [t()]
  def list_all do
    case virsh(["list", "--all", "--uuid"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&get/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Gets a single VM by UUID or name.
  """
  @spec get(String.t()) :: t() | nil
  def get(id_or_name) do
    with {:ok, dominfo} <- virsh(["dominfo", id_or_name]),
         info <- parse_dominfo(dominfo),
         {:ok, xml} <- virsh(["dumpxml", id_or_name]) do
      xml_data = parse_xml(xml)

      storage_devices = get_storage_devices(id_or_name, xml_data)
      network_interfaces = get_network_interfaces(id_or_name)
      ip_address = get_ip_address(id_or_name, info.state)

      disk_total = Enum.reduce(storage_devices, 0, fn d, acc -> acc + (d.capacity_bytes || 0) end)

      %__MODULE__{
        id: info.uuid,
        name: info.name,
        description: xml_data[:description],
        state: info.state,
        cpu_cores: info.cpu_cores,
        memory_mb: info.memory_mb,
        disk_count: length(storage_devices),
        disk_total_bytes: disk_total,
        ip_address: ip_address,
        autostart: info.autostart,
        graphics_driver: xml_data[:graphics_driver],
        storage_devices: storage_devices,
        network_interfaces: network_interfaces,
        children: nil
      }
    else
      _ -> nil
    end
  end

  @doc """
  Starts a VM (placeholder - not yet implemented).
  """
  @spec start(String.t()) :: :ok | {:error, term()}
  def start(_id) do
    # Placeholder - will call virsh start
    :ok
  end

  @doc """
  Stops a VM (placeholder - not yet implemented).
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(_id) do
    # Placeholder - will call virsh shutdown
    :ok
  end

  @doc """
  Force stops a VM (placeholder - not yet implemented).
  """
  @spec force_stop(String.t()) :: :ok | {:error, term()}
  def force_stop(_id) do
    # Placeholder - will call virsh destroy
    :ok
  end

  @doc """
  Restarts a VM (placeholder - not yet implemented).
  """
  @spec restart(String.t()) :: :ok | {:error, term()}
  def restart(_id) do
    # Placeholder - will call virsh reboot
    :ok
  end

  @doc """
  Pauses a VM (placeholder - not yet implemented).
  """
  @spec pause(String.t()) :: :ok | {:error, term()}
  def pause(_id) do
    # Placeholder - will call virsh suspend
    :ok
  end

  @doc """
  Resumes a paused VM (placeholder - not yet implemented).
  """
  @spec resume(String.t()) :: :ok | {:error, term()}
  def resume(_id) do
    # Placeholder - will call virsh resume
    :ok
  end

  @doc """
  Sets autostart for a VM (placeholder - not yet implemented).
  """
  @spec set_autostart(String.t(), boolean()) :: :ok | {:error, term()}
  def set_autostart(_id, _enabled) do
    # Placeholder - will call virsh autostart
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private - virsh command execution
  # ---------------------------------------------------------------------------

  defp virsh(args) do
    case System.cmd("virsh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Private - dominfo parsing
  # ---------------------------------------------------------------------------

  defp parse_dominfo(output) do
    lines = String.split(output, "\n", trim: true)

    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = key |> String.trim() |> String.downcase() |> String.replace(" ", "_")
          value = String.trim(value)
          Map.put(acc, key, value)

        _ ->
          acc
      end
    end)
    |> then(fn info ->
      %{
        uuid: Map.get(info, "uuid", ""),
        name: Map.get(info, "name", ""),
        state: parse_state(Map.get(info, "state", "")),
        cpu_cores: parse_int(Map.get(info, "cpu(s)", "0")),
        memory_mb: parse_memory_to_mb(Map.get(info, "max_memory", "0")),
        autostart: Map.get(info, "autostart", "disable") == "enable"
      }
    end)
  end

  defp parse_state(state) do
    case String.downcase(state) do
      "running" -> :running
      "shut off" -> :stopped
      "paused" -> :paused
      "suspended" -> :suspended
      "crashed" -> :crashed
      "idle" -> :running
      _ -> :unknown
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_memory_to_mb(str) do
    # virsh reports memory like "8388608 KiB" or "8192 MiB"
    str = String.downcase(str)

    cond do
      String.contains?(str, "gib") ->
        parse_int(str) * 1024

      String.contains?(str, "mib") ->
        parse_int(str)

      String.contains?(str, "kib") ->
        div(parse_int(str), 1024)

      true ->
        # Assume KiB if no unit
        div(parse_int(str), 1024)
    end
  end

  # ---------------------------------------------------------------------------
  # Private - XML parsing
  # ---------------------------------------------------------------------------

  defp parse_xml(xml) do
    %{
      description: extract_xml_text(xml, "description"),
      graphics_driver: extract_graphics_driver(xml)
    }
  end

  defp extract_xml_text(xml, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end

  defp extract_graphics_driver(xml) do
    graphics =
      case Regex.run(~r/<graphics[^>]*type=['"]([^'"]+)['"][^>]*>/s, xml) do
        [_, type] -> type
        _ -> nil
      end

    video =
      case Regex.run(~r/<video>.*?<model[^>]*type=['"]([^'"]+)['"][^>]*>/s, xml) do
        [_, type] -> type
        _ -> nil
      end

    case {graphics, video} do
      {nil, nil} -> nil
      {g, nil} -> "#{String.upcase(g || "")}"
      {nil, v} -> "Driver:#{String.upcase(v || "")}"
      {g, v} -> "#{String.upcase(g || "")}:auto Driver:#{String.upcase(v || "")}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private - Storage devices
  # ---------------------------------------------------------------------------

  defp get_storage_devices(id_or_name, xml_data) do
    case virsh(["domblklist", id_or_name, "--details"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(2)
        |> Enum.map(&parse_domblklist_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn device ->
          enrich_storage_device(device, id_or_name, xml_data)
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_domblklist_line(line) do
    # Format: Type  Device  Target  Source
    # e.g.:   file  disk    vda     /mnt/user/domains/vm/vdisk1.img
    parts = String.split(line, ~r/\s+/, trim: true)

    case parts do
      [_type, device_type, target, source | _] when device_type == "disk" ->
        %{
          path: source,
          target: target,
          serial: nil,
          bus: nil,
          capacity_bytes: nil,
          allocated_bytes: nil,
          boot_order: nil
        }

      _ ->
        nil
    end
  end

  defp enrich_storage_device(device, id_or_name, _xml_data) do
    # Get block info for capacity/allocation
    {capacity, allocated} =
      case virsh(["domblkinfo", id_or_name, device.target]) do
        {:ok, output} -> parse_domblkinfo(output)
        _ -> {nil, nil}
      end

    # Try to extract bus type and serial from device target name
    bus =
      cond do
        String.starts_with?(device.target, "vd") -> "VirtIO"
        String.starts_with?(device.target, "sd") -> "SATA"
        String.starts_with?(device.target, "hd") -> "IDE"
        true -> "USB"
      end

    # Generate a serial from path if not available
    serial =
      device.path
      |> Path.basename()
      |> String.replace(~r/\.(img|qcow2|raw)$/, "")

    %{
      device
      | serial: serial,
        bus: bus,
        capacity_bytes: capacity,
        allocated_bytes: allocated
    }
  end

  defp parse_domblkinfo(output) do
    lines = String.split(output, "\n", trim: true)

    info =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            key = key |> String.trim() |> String.downcase()
            value = String.trim(value)
            Map.put(acc, key, value)

          _ ->
            acc
        end
      end)

    capacity = parse_int(Map.get(info, "capacity", "0"))
    allocated = parse_int(Map.get(info, "allocation", "0"))

    {capacity, allocated}
  end

  # ---------------------------------------------------------------------------
  # Private - Network interfaces
  # ---------------------------------------------------------------------------

  defp get_network_interfaces(id_or_name) do
    case virsh(["domiflist", id_or_name]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(2)
        |> Enum.map(&parse_domiflist_line/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_domiflist_line(line) do
    # Format: Interface  Type     Source    Model    MAC
    # e.g.:   vnet0      bridge   br0       virtio   52:54:00:ab:cd:ef
    parts = String.split(line, ~r/\s+/, trim: true)

    case parts do
      [_interface, _type, source, model, mac | _] ->
        %{
          mac: mac,
          bridge: source,
          type: model
        }

      [_interface, type, source, mac | _] ->
        %{
          mac: mac,
          bridge: source,
          type: type
        }

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private - IP address
  # ---------------------------------------------------------------------------

  defp get_ip_address(_id_or_name, state) when state != :running do
    nil
  end

  defp get_ip_address(id_or_name, :running) do
    case virsh(["domifaddr", id_or_name]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(2)
        |> Enum.find_value(fn line ->
          case Regex.run(~r/(\d+\.\d+\.\d+\.\d+)/, line) do
            [_, ip] -> ip
            _ -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  @doc """
  Formats bytes to a human-readable string (e.g., "5G", "500M").
  """
  @spec format_bytes(non_neg_integer() | nil) :: String.t()
  def format_bytes(nil), do: "—"
  def format_bytes(0), do: "0"

  def format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{div(bytes, 1_073_741_824)}G"
  end

  def format_bytes(bytes) when bytes >= 1_048_576 do
    "#{div(bytes, 1_048_576)}M"
  end

  def format_bytes(bytes) when bytes >= 1024 do
    "#{div(bytes, 1024)}K"
  end

  def format_bytes(bytes), do: "#{bytes}B"

  @doc """
  Formats memory in MB to a human-readable string.
  """
  @spec format_memory(non_neg_integer() | nil) :: String.t()
  def format_memory(nil), do: "—"

  def format_memory(mb) when mb >= 1024 do
    "#{div(mb, 1024)}G"
  end

  def format_memory(mb), do: "#{mb}M"
end
