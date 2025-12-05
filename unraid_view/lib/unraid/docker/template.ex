defmodule Unraid.Docker.Template do
  @moduledoc """
  Struct representing a Docker container XML template.

  Maps 1:1 with the webgui XML template format (version 2).
  This struct is used for reading, editing, and persisting container configurations.
  """

  import SweetXml

  alias Unraid.Parse

  @type config_type :: :port | :path | :variable | :label | :device

  @type config_item :: %{
          name: String.t(),
          target: String.t(),
          default: String.t(),
          value: String.t(),
          mode: String.t(),
          type: config_type(),
          display: String.t(),
          required: boolean(),
          mask: boolean(),
          description: String.t()
        }

  @type tailscale_config :: %{
          enabled: boolean(),
          hostname: String.t() | nil,
          is_exit_node: boolean(),
          exit_node_ip: String.t() | nil,
          ssh: String.t() | nil,
          userspace_networking: String.t() | nil,
          lan_access: String.t() | nil,
          serve: String.t() | nil,
          serve_port: String.t() | nil,
          serve_target: String.t() | nil,
          serve_local_path: String.t() | nil,
          serve_protocol: String.t() | nil,
          serve_protocol_port: String.t() | nil,
          serve_path: String.t() | nil,
          web_ui: String.t() | nil,
          routes: String.t() | nil,
          accept_routes: boolean(),
          daemon_params: String.t() | nil,
          extra_params: String.t() | nil,
          state_dir: String.t() | nil,
          troubleshooting: boolean()
        }

  @type t :: %__MODULE__{
          # Identity
          name: String.t(),
          repository: String.t(),
          registry: String.t() | nil,

          # Network
          network: String.t(),
          my_ip: String.t() | nil,

          # Execution
          shell: String.t(),
          privileged: boolean(),
          extra_params: String.t() | nil,
          post_args: String.t() | nil,
          cpuset: String.t() | nil,

          # UI/Metadata
          web_ui: String.t() | nil,
          icon: String.t() | nil,
          overview: String.t() | nil,
          category: String.t() | nil,
          support: String.t() | nil,
          project: String.t() | nil,
          template_url: String.t() | nil,
          donate_text: String.t() | nil,
          donate_link: String.t() | nil,
          requires: String.t() | nil,
          date_installed: integer() | nil,

          # Config items (ports, paths, variables, labels, devices)
          configs: [config_item()],

          # Tailscale
          tailscale: tailscale_config() | nil
        }

  defstruct [
    :name,
    :repository,
    :registry,
    :network,
    :my_ip,
    :shell,
    :privileged,
    :extra_params,
    :post_args,
    :cpuset,
    :web_ui,
    :icon,
    :overview,
    :category,
    :support,
    :project,
    :template_url,
    :donate_text,
    :donate_link,
    :requires,
    :date_installed,
    :configs,
    :tailscale
  ]

  # ---------------------------------------------------------------------------
  # XML Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parse an XML string into a Template struct.
  """
  def from_xml(xml_string) when is_binary(xml_string) do
    try do
      doc = parse(xml_string)

      template = %__MODULE__{
        name: xpath(doc, ~x"//Name/text()"s) |> decode_xml(),
        repository: xpath(doc, ~x"//Repository/text()"s) |> decode_xml(),
        registry: xpath(doc, ~x"//Registry/text()"s) |> decode_xml() |> nilify(),
        network: xpath(doc, ~x"//Network/text()"s) |> decode_xml(),
        my_ip: xpath(doc, ~x"//MyIP/text()"s) |> decode_xml() |> nilify(),
        shell: xpath(doc, ~x"//Shell/text()"s) |> decode_xml() |> default("sh"),
        privileged: xpath(doc, ~x"//Privileged/text()"s) |> to_boolean(),
        extra_params: xpath(doc, ~x"//ExtraParams/text()"s) |> decode_xml() |> nilify(),
        post_args: xpath(doc, ~x"//PostArgs/text()"s) |> decode_xml() |> nilify(),
        cpuset: xpath(doc, ~x"//CPUset/text()"s) |> decode_xml() |> nilify(),
        web_ui: xpath(doc, ~x"//WebUI/text()"s) |> decode_xml() |> nilify(),
        icon: xpath(doc, ~x"//Icon/text()"s) |> decode_xml() |> nilify(),
        overview: xpath(doc, ~x"//Overview/text()"s) |> decode_xml() |> nilify(),
        category: xpath(doc, ~x"//Category/text()"s) |> decode_xml() |> nilify(),
        support: xpath(doc, ~x"//Support/text()"s) |> decode_xml() |> nilify(),
        project: xpath(doc, ~x"//Project/text()"s) |> decode_xml() |> nilify(),
        template_url: xpath(doc, ~x"//TemplateURL/text()"s) |> decode_xml() |> nilify(),
        donate_text: xpath(doc, ~x"//DonateText/text()"s) |> decode_xml() |> nilify(),
        donate_link: xpath(doc, ~x"//DonateLink/text()"s) |> decode_xml() |> nilify(),
        requires: xpath(doc, ~x"//Requires/text()"s) |> decode_xml() |> nilify(),
        date_installed: xpath(doc, ~x"//DateInstalled/text()"s) |> to_integer(),
        configs: parse_configs(doc),
        tailscale: parse_tailscale(doc)
      }

      {:ok, template}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp parse_configs(doc) do
    doc
    |> xpath(~x"//Config"l)
    |> Enum.map(fn config_node ->
      %{
        name: xpath(config_node, ~x"./@Name"s) |> decode_xml(),
        target: xpath(config_node, ~x"./@Target"s) |> decode_xml(),
        default: xpath(config_node, ~x"./@Default"s) |> decode_xml(),
        value: xpath(config_node, ~x"./text()"s) |> decode_xml(),
        mode: xpath(config_node, ~x"./@Mode"s) |> decode_xml() |> default_mode_for_type(
          xpath(config_node, ~x"./@Type"s)
        ),
        type: xpath(config_node, ~x"./@Type"s) |> parse_config_type(),
        display: xpath(config_node, ~x"./@Display"s) |> decode_xml() |> default("always"),
        required: xpath(config_node, ~x"./@Required"s) |> to_boolean(),
        mask: xpath(config_node, ~x"./@Mask"s) |> to_boolean(),
        description: xpath(config_node, ~x"./@Description"s) |> decode_xml()
      }
    end)
  end

  defp parse_tailscale(doc) do
    enabled = xpath(doc, ~x"//TailscaleEnabled/text()"s) |> to_boolean()

    if enabled do
      %{
        enabled: true,
        hostname: xpath(doc, ~x"//TailscaleHostname/text()"s) |> decode_xml() |> nilify(),
        is_exit_node: xpath(doc, ~x"//TailscaleIsExitNode/text()"s) |> to_boolean(),
        exit_node_ip: xpath(doc, ~x"//TailscaleExitNodeIP/text()"s) |> decode_xml() |> nilify(),
        ssh: xpath(doc, ~x"//TailscaleSSH/text()"s) |> decode_xml() |> nilify(),
        userspace_networking: xpath(doc, ~x"//TailscaleUserspaceNetworking/text()"s) |> decode_xml() |> nilify(),
        lan_access: xpath(doc, ~x"//TailscaleLANAccess/text()"s) |> decode_xml() |> nilify(),
        serve: xpath(doc, ~x"//TailscaleServe/text()"s) |> decode_xml() |> nilify(),
        serve_port: xpath(doc, ~x"//TailscaleServePort/text()"s) |> decode_xml() |> nilify(),
        serve_target: xpath(doc, ~x"//TailscaleServeTarget/text()"s) |> decode_xml() |> nilify(),
        serve_local_path: xpath(doc, ~x"//TailscaleServeLocalPath/text()"s) |> decode_xml() |> nilify(),
        serve_protocol: xpath(doc, ~x"//TailscaleServeProtocol/text()"s) |> decode_xml() |> nilify(),
        serve_protocol_port: xpath(doc, ~x"//TailscaleServeProtocolPort/text()"s) |> decode_xml() |> nilify(),
        serve_path: xpath(doc, ~x"//TailscaleServePath/text()"s) |> decode_xml() |> nilify(),
        web_ui: xpath(doc, ~x"//TailscaleWebUI/text()"s) |> decode_xml() |> nilify(),
        routes: xpath(doc, ~x"//TailscaleRoutes/text()"s) |> decode_xml() |> nilify(),
        accept_routes: xpath(doc, ~x"//TailscaleAcceptRoutes/text()"s) |> to_boolean(),
        daemon_params: xpath(doc, ~x"//TailscaleDParams/text()"s) |> decode_xml() |> nilify(),
        extra_params: xpath(doc, ~x"//TailscaleParams/text()"s) |> decode_xml() |> nilify(),
        state_dir: xpath(doc, ~x"//TailscaleStateDir/text()"s) |> decode_xml() |> nilify(),
        troubleshooting: xpath(doc, ~x"//TailscaleTroubleshooting/text()"s) |> to_boolean()
      }
    else
      # Check if state_dir exists even without tailscale enabled
      state_dir = xpath(doc, ~x"//TailscaleStateDir/text()"s) |> decode_xml() |> nilify()

      if state_dir do
        %{
          enabled: false,
          hostname: nil,
          is_exit_node: false,
          exit_node_ip: nil,
          ssh: nil,
          userspace_networking: nil,
          lan_access: nil,
          serve: nil,
          serve_port: nil,
          serve_target: nil,
          serve_local_path: nil,
          serve_protocol: nil,
          serve_protocol_port: nil,
          serve_path: nil,
          web_ui: nil,
          routes: nil,
          accept_routes: false,
          daemon_params: nil,
          extra_params: nil,
          state_dir: state_dir,
          troubleshooting: false
        }
      else
        nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # XML Generation
  # ---------------------------------------------------------------------------

  @doc """
  Convert a Template struct to an XML string.
  """
  def to_xml(%__MODULE__{} = template) do
    import XmlBuilder

    configs =
      Enum.map(template.configs, fn c ->
        element(
          :Config,
          %{
            "Name" => c.name,
            "Target" => c.target,
            "Default" => c.default,
            "Mode" => c.mode,
            "Type" => config_type_to_string(c.type),
            "Display" => c.display,
            "Required" => to_string(c.required),
            "Mask" => to_string(c.mask),
            "Description" => c.description || ""
          },
          encode_xml(c.value)
        )
      end)

    base_elements = [
      element(:Name, encode_xml(template.name)),
      element(:Repository, encode_xml(template.repository)),
      element(:Registry, encode_xml(template.registry || "")),
      element(:Network, encode_xml(template.network)),
      element(:MyIP, encode_xml(template.my_ip || "")),
      element(:Shell, encode_xml(template.shell || "sh")),
      element(:Privileged, if(template.privileged, do: "true", else: "false")),
      element(:Support, encode_xml(template.support || "")),
      element(:Project, encode_xml(template.project || "")),
      element(:Overview, encode_xml(template.overview || "")),
      element(:Category, encode_xml(template.category || "")),
      element(:WebUI, encode_xml(template.web_ui || "")),
      element(:TemplateURL, encode_xml(template.template_url || "")),
      element(:Icon, encode_xml(template.icon || "")),
      element(:ExtraParams, encode_xml(template.extra_params || "")),
      element(:PostArgs, encode_xml(template.post_args || "")),
      element(:CPUset, encode_xml(template.cpuset || "")),
      element(:DateInstalled, to_string(template.date_installed || :os.system_time(:second))),
      element(:DonateText, encode_xml(template.donate_text || "")),
      element(:DonateLink, encode_xml(template.donate_link || "")),
      element(:Requires, encode_xml(template.requires || ""))
    ]

    tailscale_elements = build_tailscale_elements(template.tailscale)

    doc =
      element(
        :Container,
        %{version: "2"},
        base_elements ++ configs ++ tailscale_elements
      )

    XmlBuilder.document(doc)
    |> XmlBuilder.generate(format: :indent)
  end

  defp build_tailscale_elements(nil), do: []

  defp build_tailscale_elements(ts) do
    import XmlBuilder

    base = [
      element(:TailscaleEnabled, if(ts.enabled, do: "true", else: "false"))
    ]

    if ts.enabled do
      base ++
        [
          element(:TailscaleIsExitNode, encode_xml(if(ts.is_exit_node, do: "true", else: ""))),
          element(:TailscaleHostname, encode_xml(ts.hostname || "")),
          element(:TailscaleExitNodeIP, encode_xml(ts.exit_node_ip || "")),
          element(:TailscaleSSH, encode_xml(ts.ssh || "")),
          element(:TailscaleUserspaceNetworking, encode_xml(ts.userspace_networking || "")),
          element(:TailscaleLANAccess, encode_xml(ts.lan_access || "")),
          element(:TailscaleServe, encode_xml(ts.serve || "")),
          element(:TailscaleWebUI, encode_xml(ts.web_ui || ""))
        ] ++
        if ts.serve && ts.serve not in ["no", ""] do
          [
            element(:TailscaleServePort, encode_xml(ts.serve_port || "")),
            element(:TailscaleServeTarget, encode_xml(ts.serve_target || "")),
            element(:TailscaleServeLocalPath, encode_xml(ts.serve_local_path || "")),
            element(:TailscaleServeProtocol, encode_xml(ts.serve_protocol || "")),
            element(:TailscaleServeProtocolPort, encode_xml(ts.serve_protocol_port || "")),
            element(:TailscaleServePath, encode_xml(ts.serve_path || ""))
          ]
        else
          []
        end ++
        [
          element(:TailscaleDParams, encode_xml(ts.daemon_params || "")),
          element(:TailscaleParams, encode_xml(ts.extra_params || "")),
          element(:TailscaleRoutes, encode_xml(ts.routes || "")),
          element(:TailscaleAcceptRoutes, encode_xml(if(ts.accept_routes, do: "true", else: ""))),
          element(:TailscaleTroubleshooting, if(ts.troubleshooting, do: "true", else: "")),
          element(:TailscaleStateDir, encode_xml(ts.state_dir || ""))
        ]
    else
      # Only include state_dir if it exists
      if ts.state_dir do
        [element(:TailscaleStateDir, encode_xml(ts.state_dir))]
      else
        []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Config Item Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Get all port config items.
  """
  def ports(%__MODULE__{configs: configs}) do
    Enum.filter(configs, &(&1.type == :port))
  end

  @doc """
  Get all path/volume config items.
  """
  def paths(%__MODULE__{configs: configs}) do
    Enum.filter(configs, &(&1.type == :path))
  end

  @doc """
  Get all environment variable config items.
  """
  def variables(%__MODULE__{configs: configs}) do
    Enum.filter(configs, &(&1.type == :variable))
  end

  @doc """
  Get all label config items.
  """
  def labels(%__MODULE__{configs: configs}) do
    Enum.filter(configs, &(&1.type == :label))
  end

  @doc """
  Get all device config items.
  """
  def devices(%__MODULE__{configs: configs}) do
    Enum.filter(configs, &(&1.type == :device))
  end

  @doc """
  Add a new config item to the template.
  """
  def add_config(%__MODULE__{configs: configs} = template, config_item) do
    %{template | configs: configs ++ [config_item]}
  end

  @doc """
  Remove a config item by index.
  """
  def remove_config(%__MODULE__{configs: configs} = template, index) when is_integer(index) do
    %{template | configs: List.delete_at(configs, index)}
  end

  @doc """
  Update a config item at the given index.
  """
  def update_config(%__MODULE__{configs: configs} = template, index, attrs) when is_integer(index) do
    updated_configs =
      List.update_at(configs, index, fn config ->
        Map.merge(config, attrs)
      end)

    %{template | configs: updated_configs}
  end

  @doc """
  Create a new empty config item of the given type.
  """
  def new_config(type) when type in [:port, :path, :variable, :label, :device] do
    %{
      name: "",
      target: "",
      default: "",
      value: "",
      mode: default_mode(type),
      type: type,
      display: "always",
      required: false,
      mask: false,
      description: ""
    }
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate a template for required fields.
  Returns {:ok, template} or {:error, errors}.
  """
  def validate(%__MODULE__{} = template) do
    errors = []

    errors =
      if is_nil(template.name) or template.name == "" do
        ["Container name is required" | errors]
      else
        errors
      end

    errors =
      if is_nil(template.repository) or template.repository == "" do
        ["Repository/image is required" | errors]
      else
        errors
      end

    errors =
      if is_nil(template.network) or template.network == "" do
        ["Network mode is required" | errors]
      else
        errors
      end

    # Validate config items
    config_errors =
      template.configs
      |> Enum.with_index()
      |> Enum.flat_map(fn {config, index} ->
        validate_config(config, index)
      end)

    errors = errors ++ config_errors

    if errors == [] do
      {:ok, template}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp validate_config(config, index) do
    errors = []

    errors =
      if config.type in [:port, :path, :variable] and
           (is_nil(config.target) or config.target == "") do
        ["Config item #{index + 1}: Target is required for #{config.type}" | errors]
      else
        errors
      end

    errors
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp decode_xml(value) when is_binary(value) do
    # Decode common XML entities
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
  end

  defp decode_xml(value), do: to_string(value)

  defp encode_xml(nil), do: ""
  defp encode_xml(value) when is_binary(value), do: value
  defp encode_xml(value), do: to_string(value)

  defp nilify(value), do: Parse.nilify(value)

  defp default(value, default_value), do: Parse.default(value, default_value)

  defp to_boolean(value), do: Parse.boolean_or_default(value, false)

  defp to_integer(value), do: Parse.integer_or_nil(value)

  defp parse_config_type(type) when is_binary(type) do
    case String.downcase(type) do
      "port" -> :port
      "path" -> :path
      "variable" -> :variable
      "label" -> :label
      "device" -> :device
      _ -> :variable
    end
  end

  defp parse_config_type(_), do: :variable

  defp config_type_to_string(:port), do: "Port"
  defp config_type_to_string(:path), do: "Path"
  defp config_type_to_string(:variable), do: "Variable"
  defp config_type_to_string(:label), do: "Label"
  defp config_type_to_string(:device), do: "Device"
  defp config_type_to_string(_), do: "Variable"

  defp default_mode(:port), do: "tcp"
  defp default_mode(:path), do: "rw"
  defp default_mode(_), do: ""

  defp default_mode_for_type("", type) do
    case String.downcase(type || "") do
      "port" -> "tcp"
      "path" -> "rw"
      _ -> ""
    end
  end

  defp default_mode_for_type(mode, _type), do: mode
end
