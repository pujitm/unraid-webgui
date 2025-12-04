defmodule Unraid.Docker.TailscaleStatus do
  @moduledoc """
  Struct representing the Tailscale status for a Docker container.

  This struct normalizes the Tailscale status JSON response into a consistent format
  for use in LiveViews and other UI components.
  """

  @type exit_node_status :: %{
          online: boolean(),
          tailscale_ips: [String.t()]
        }

  @type t :: %__MODULE__{
          online: boolean(),
          version: String.t() | nil,
          latest_version: String.t() | nil,
          update_available: boolean(),
          hostname: String.t() | nil,
          dns_name: String.t() | nil,
          relay: String.t() | nil,
          relay_name: String.t() | nil,
          tailscale_ips: [String.t()],
          primary_routes: [String.t()],
          is_exit_node: boolean(),
          exit_node_status: exit_node_status() | nil,
          web_ui_url: String.t() | nil,
          key_expiry: DateTime.t() | nil,
          key_expiry_days: integer() | nil,
          key_expired: boolean(),
          backend_state: String.t() | nil,
          auth_url: String.t() | nil
        }

  defstruct [
    :online,
    :version,
    :latest_version,
    :update_available,
    :hostname,
    :dns_name,
    :relay,
    :relay_name,
    :tailscale_ips,
    :primary_routes,
    :is_exit_node,
    :exit_node_status,
    :web_ui_url,
    :key_expiry,
    :key_expiry_days,
    :key_expired,
    :backend_state,
    :auth_url
  ]

  @doc """
  Creates a TailscaleStatus struct from raw Tailscale JSON response.

  ## Options
    - `:hostname` - The configured hostname from container labels
    - `:webui_template` - The WebUI URL template from container labels
    - `:derp_map` - The DERP map for resolving relay names
    - `:latest_version` - The latest available Tailscale version
  """
  def from_raw(raw_status, opts \\ []) when is_map(raw_status) do
    hostname = Keyword.get(opts, :hostname)
    webui_template = Keyword.get(opts, :webui_template)
    derp_map = Keyword.get(opts, :derp_map)
    latest_version = Keyword.get(opts, :latest_version)

    self_status = raw_status["Self"] || %{}
    exit_node_status = raw_status["ExitNodeStatus"]

    # Parse version (strip build info after dash)
    version =
      case raw_status["Version"] do
        nil -> nil
        v -> v |> String.split("-") |> List.first()
      end

    # Calculate update availability
    update_available = version_less_than?(version, latest_version)

    # Parse DNS name and extract actual hostname
    dns_name = self_status["DNSName"] |> normalize_dns_name()

    # Map relay code to region name
    relay = self_status["Relay"]
    relay_name = if relay && derp_map, do: map_relay_to_region(relay, derp_map), else: nil

    # Parse key expiry
    {key_expiry, key_expiry_days, key_expired} = parse_key_expiry(self_status["KeyExpiry"])

    # Resolve WebUI URL
    web_ui_url = resolve_web_ui_url(webui_template, self_status)

    %__MODULE__{
      online: self_status["Online"] == true,
      version: version,
      latest_version: latest_version,
      update_available: update_available,
      hostname: hostname,
      dns_name: dns_name,
      relay: relay,
      relay_name: relay_name,
      tailscale_ips: self_status["TailscaleIPs"] || [],
      primary_routes: self_status["PrimaryRoutes"] || [],
      is_exit_node: self_status["ExitNodeOption"] == true,
      exit_node_status: parse_exit_node_status(exit_node_status),
      web_ui_url: web_ui_url,
      key_expiry: key_expiry,
      key_expiry_days: key_expiry_days,
      key_expired: key_expired,
      backend_state: raw_status["BackendState"],
      auth_url: raw_status["AuthURL"]
    }
  end

  @doc """
  Creates an offline/error TailscaleStatus.
  """
  def offline(hostname \\ nil) do
    %__MODULE__{
      online: false,
      version: nil,
      latest_version: nil,
      update_available: false,
      hostname: hostname,
      dns_name: nil,
      relay: nil,
      relay_name: nil,
      tailscale_ips: [],
      primary_routes: [],
      is_exit_node: false,
      exit_node_status: nil,
      web_ui_url: nil,
      key_expiry: nil,
      key_expiry_days: nil,
      key_expired: false,
      backend_state: nil,
      auth_url: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp normalize_dns_name(nil), do: nil
  defp normalize_dns_name(""), do: nil
  defp normalize_dns_name(dns_name), do: String.trim_trailing(dns_name, ".")

  defp parse_key_expiry(nil), do: {nil, nil, false}

  defp parse_key_expiry(expiry_str) when is_binary(expiry_str) do
    case DateTime.from_iso8601(expiry_str) do
      {:ok, expiry, _offset} ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(expiry, now)
        days = div(diff_seconds, 86400)
        expired = diff_seconds < 0

        {expiry, days, expired}

      _ ->
        {nil, nil, false}
    end
  end

  defp parse_exit_node_status(nil), do: nil

  defp parse_exit_node_status(status) when is_map(status) do
    %{
      online: status["Online"] == true,
      tailscale_ips: status["TailscaleIPs"] || []
    }
  end

  defp map_relay_to_region(_relay_code, nil), do: nil

  defp map_relay_to_region(relay_code, derp_map) do
    regions = derp_map["Regions"] || %{}

    regions
    |> Map.values()
    |> Enum.find_value(fn region ->
      if region["RegionCode"] == relay_code do
        region["RegionName"]
      end
    end)
  end

  defp version_less_than?(nil, _latest), do: false
  defp version_less_than?(_current, nil), do: false

  defp version_less_than?(current, latest) do
    current_parts = current |> String.split(".") |> Enum.map(&parse_int/1)
    latest_parts = latest |> String.split(".") |> Enum.map(&parse_int/1)

    compare_version_parts(current_parts, latest_parts)
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp compare_version_parts([], []), do: false
  defp compare_version_parts([], [_ | _]), do: true
  defp compare_version_parts([_ | _], []), do: false

  defp compare_version_parts([c | c_rest], [l | l_rest]) do
    cond do
      c < l -> true
      c > l -> false
      true -> compare_version_parts(c_rest, l_rest)
    end
  end

  defp resolve_web_ui_url(nil, _status), do: nil
  defp resolve_web_ui_url("", _status), do: nil

  defp resolve_web_ui_url(template, status) do
    dns_name = status["DNSName"] |> normalize_dns_name()
    tailscale_ips = status["TailscaleIPs"] || []
    ipv4 = Enum.find(tailscale_ips, &(!String.contains?(&1, ":")))

    cond do
      String.contains?(template, "[hostname]") ->
        if dns_name do
          template
          |> String.replace("[hostname][magicdns]", dns_name)
          |> String.replace("[hostname]", dns_name)
          |> String.replace("[IP]", dns_name)
          |> replace_port_with_443()
        else
          nil
        end

      String.contains?(template, "[noserve]") ->
        if ipv4 do
          port = extract_port(template)
          port_suffix = if port, do: ":#{port}", else: ""
          "http://#{ipv4}#{port_suffix}"
        else
          nil
        end

      true ->
        template
        |> maybe_replace_ip(ipv4, tailscale_ips)
        |> maybe_replace_port()
    end
  end

  defp replace_port_with_443(url) do
    Regex.replace(~r/\[PORT:\d+\]/, url, "443")
  end

  defp extract_port(template) do
    case Regex.run(~r/\[PORT:(\d+)\]/, template) do
      [_, port] -> port
      _ -> nil
    end
  end

  defp maybe_replace_ip(url, nil, [first | _]) when is_binary(first) do
    String.replace(url, "[IP]", first)
  end

  defp maybe_replace_ip(url, ipv4, _ips) when is_binary(ipv4) do
    String.replace(url, "[IP]", ipv4)
  end

  defp maybe_replace_ip(url, _, _), do: url

  defp maybe_replace_port(url) do
    case Regex.run(~r/\[PORT:(\d+)\]/, url) do
      [match, port] -> String.replace(url, match, port)
      _ -> url
    end
  end
end
