defmodule Unraid.Docker.TemplateTest do
  use ExUnit.Case, async: true

  alias Unraid.Docker.Template

  @fixtures_path "test/fixtures/templates"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fixture_path(name) do
    Path.join(@fixtures_path, name)
  end

  defp read_fixture(name) do
    fixture_path(name) |> File.read!()
  end

  # ---------------------------------------------------------------------------
  # XML Parsing Tests
  # ---------------------------------------------------------------------------

  describe "from_xml/1 - simple container" do
    setup do
      xml = read_fixture("simple_container.xml")
      {:ok, template} = Template.from_xml(xml)
      %{template: template, xml: xml}
    end

    test "parses basic fields", %{template: t} do
      assert t.name == "nginx"
      assert t.repository == "nginx:latest"
      assert t.registry == "https://hub.docker.com/r/library/nginx/"
      assert t.network == "bridge"
      assert t.shell == "sh"
      assert t.privileged == false
    end

    test "parses UI metadata", %{template: t} do
      assert t.web_ui == "http://[IP]:[PORT:80]/"
      assert t.icon == "https://raw.githubusercontent.com/nginx/nginx/master/docs/icon.png"
      assert t.overview == "Nginx is a web server."
      assert t.category == "Network:Web"
    end

    test "parses config items", %{template: t} do
      assert length(t.configs) == 2

      port_config = Enum.find(t.configs, &(&1.type == :port))
      assert port_config.name == "WebUI Port"
      assert port_config.target == "80"
      assert port_config.value == "8080"
      assert port_config.default == "8080"
      assert port_config.mode == "tcp"
      assert port_config.required == true

      path_config = Enum.find(t.configs, &(&1.type == :path))
      assert path_config.name == "Config Path"
      assert path_config.target == "/etc/nginx"
      assert path_config.value == "/mnt/user/appdata/nginx"
      assert path_config.mode == "rw"
    end

    test "tailscale is nil when not configured", %{template: t} do
      assert t.tailscale == nil
    end
  end

  describe "from_xml/1 - complex container" do
    setup do
      xml = read_fixture("complex_container.xml")
      {:ok, template} = Template.from_xml(xml)
      %{template: template}
    end

    test "parses advanced fields", %{template: t} do
      assert t.cpuset == "0,1,2,3"
      assert t.extra_params == "--memory=4g --restart=unless-stopped"
      assert t.shell == "bash"
    end

    test "parses all config types", %{template: t} do
      ports = Template.ports(t)
      paths = Template.paths(t)
      variables = Template.variables(t)
      devices = Template.devices(t)
      labels = Template.labels(t)

      assert length(ports) == 0  # host network mode, no ports
      assert length(paths) == 3
      assert length(variables) == 3
      assert length(devices) == 1
      assert length(labels) == 1
    end

    test "parses device config", %{template: t} do
      device = hd(Template.devices(t))
      assert device.target == "/dev/dri"
      assert device.value == "/dev/dri"
    end

    test "parses label config", %{template: t} do
      label = hd(Template.labels(t))
      assert label.target == "net.unraid.docker.managed"
      assert label.value == "dockerman"
    end

    test "parses variable with mask", %{template: t} do
      claim_var = Enum.find(t.configs, &(&1.name == "Plex Claim"))
      assert claim_var.mask == true
    end
  end

  describe "from_xml/1 - tailscale container" do
    setup do
      xml = read_fixture("tailscale_container.xml")
      {:ok, template} = Template.from_xml(xml)
      %{template: template}
    end

    test "parses tailscale enabled", %{template: t} do
      assert t.tailscale != nil
      assert t.tailscale.enabled == true
    end

    test "parses tailscale basic settings", %{template: t} do
      ts = t.tailscale
      assert ts.hostname == "pihole-server"
      assert ts.is_exit_node == false
      assert ts.ssh == "true"
      assert ts.userspace_networking == "false"
      assert ts.lan_access == "true"
    end

    test "parses tailscale serve settings", %{template: t} do
      ts = t.tailscale
      assert ts.serve == "serve"
      assert ts.serve_port == "443"
      assert ts.serve_target == "http://localhost:80"
      assert ts.web_ui == "https://[hostname][magicdns]/admin"
    end

    test "parses tailscale routes", %{template: t} do
      ts = t.tailscale
      assert ts.routes == "192.168.1.0/24"
      assert ts.accept_routes == true
    end

    test "parses tailscale state dir", %{template: t} do
      ts = t.tailscale
      assert ts.state_dir == "/mnt/user/appdata/tailscale/pihole"
    end

    test "parses fixed IP address", %{template: t} do
      assert t.my_ip == "192.168.1.100"
    end
  end

  describe "from_xml/1 - special characters" do
    setup do
      xml = read_fixture("special_chars_container.xml")
      {:ok, template} = Template.from_xml(xml)
      %{template: template}
    end

    test "decodes XML entities in overview", %{template: t} do
      assert t.overview =~ "<script>alert(\"test\")</script>"
      assert t.overview =~ "& \"quotes\""
    end

    test "decodes XML entities in web UI", %{template: t} do
      assert t.web_ui =~ "param=value&other=test"
    end

    test "preserves special chars in config values", %{template: t} do
      secret = Enum.find(t.configs, &(&1.name =~ "Secret"))
      assert secret.value =~ "p@$$w0rd!"

      json = Enum.find(t.configs, &(&1.name =~ "JSON"))
      assert json.value == "{\"key\": \"value\", \"nested\": {\"a\": 1}}"
    end

    test "preserves paths with spaces", %{template: t} do
      path = Enum.find(t.configs, &(&1.name =~ "Path with spaces"))
      assert path.value == "/mnt/user/appdata/special app"
    end
  end

  # ---------------------------------------------------------------------------
  # XML Generation Tests
  # ---------------------------------------------------------------------------

  describe "to_xml/1" do
    test "generates valid XML" do
      template = %Template{
        name: "test-container",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      xml = Template.to_xml(template)

      assert xml =~ "<?xml version="
      assert xml =~ "<Container version=\"2\">"
      assert xml =~ "<Name>test-container</Name>"
      assert xml =~ "<Repository>test:latest</Repository>"
      assert xml =~ "</Container>"
    end

    test "generates config items" do
      template = %Template{
        name: "test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [
          %{
            name: "Port 80",
            target: "80",
            default: "8080",
            value: "8080",
            mode: "tcp",
            type: :port,
            display: "always",
            required: true,
            mask: false,
            description: "Web port"
          }
        ],
        tailscale: nil
      }

      xml = Template.to_xml(template)

      assert xml =~ "<Config"
      assert xml =~ "Name=\"Port 80\""
      assert xml =~ "Target=\"80\""
      assert xml =~ "Type=\"Port\""
      assert xml =~ "Mode=\"tcp\""
    end

    test "generates tailscale settings" do
      template = %Template{
        name: "test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: %{
          enabled: true,
          hostname: "test-host",
          is_exit_node: false,
          exit_node_ip: nil,
          ssh: "true",
          userspace_networking: nil,
          lan_access: nil,
          serve: "serve",
          serve_port: "443",
          serve_target: "http://localhost:80",
          serve_local_path: nil,
          serve_protocol: nil,
          serve_protocol_port: nil,
          serve_path: nil,
          web_ui: "https://[hostname]/",
          routes: nil,
          accept_routes: false,
          daemon_params: nil,
          extra_params: nil,
          state_dir: "/data/tailscale",
          troubleshooting: false
        }
      }

      xml = Template.to_xml(template)

      assert xml =~ "<TailscaleEnabled>true</TailscaleEnabled>"
      assert xml =~ "<TailscaleHostname>test-host</TailscaleHostname>"
      assert xml =~ "<TailscaleSSH>true</TailscaleSSH>"
      assert xml =~ "<TailscaleServe>serve</TailscaleServe>"
      assert xml =~ "<TailscaleStateDir>/data/tailscale</TailscaleStateDir>"
    end
  end

  # ---------------------------------------------------------------------------
  # Roundtrip Tests - Critical for ensuring no data corruption
  # ---------------------------------------------------------------------------

  describe "roundtrip - parse then generate" do
    test "simple container roundtrip preserves all data" do
      original_xml = read_fixture("simple_container.xml")
      {:ok, template} = Template.from_xml(original_xml)
      generated_xml = Template.to_xml(template)
      {:ok, reparsed} = Template.from_xml(generated_xml)

      # Core fields
      assert reparsed.name == template.name
      assert reparsed.repository == template.repository
      assert reparsed.registry == template.registry
      assert reparsed.network == template.network
      assert reparsed.shell == template.shell
      assert reparsed.privileged == template.privileged

      # UI fields
      assert reparsed.web_ui == template.web_ui
      assert reparsed.icon == template.icon
      assert reparsed.overview == template.overview

      # Configs
      assert length(reparsed.configs) == length(template.configs)

      for {orig, repr} <- Enum.zip(template.configs, reparsed.configs) do
        assert repr.name == orig.name
        assert repr.target == orig.target
        assert repr.value == orig.value
        assert repr.default == orig.default
        assert repr.mode == orig.mode
        assert repr.type == orig.type
        assert repr.required == orig.required
        assert repr.mask == orig.mask
      end
    end

    test "complex container roundtrip preserves all config types" do
      original_xml = read_fixture("complex_container.xml")
      {:ok, template} = Template.from_xml(original_xml)
      generated_xml = Template.to_xml(template)
      {:ok, reparsed} = Template.from_xml(generated_xml)

      # Verify all config types survived roundtrip
      for type <- [:port, :path, :variable, :device, :label] do
        orig_count = template.configs |> Enum.count(&(&1.type == type))
        repr_count = reparsed.configs |> Enum.count(&(&1.type == type))
        assert repr_count == orig_count, "Config type #{type} count mismatch"
      end

      # Verify advanced fields
      assert reparsed.cpuset == template.cpuset
      assert reparsed.extra_params == template.extra_params
    end

    test "tailscale container roundtrip preserves all tailscale settings" do
      original_xml = read_fixture("tailscale_container.xml")
      {:ok, template} = Template.from_xml(original_xml)
      generated_xml = Template.to_xml(template)
      {:ok, reparsed} = Template.from_xml(generated_xml)

      assert reparsed.tailscale != nil
      assert reparsed.tailscale.enabled == template.tailscale.enabled
      assert reparsed.tailscale.hostname == template.tailscale.hostname
      assert reparsed.tailscale.ssh == template.tailscale.ssh
      assert reparsed.tailscale.serve == template.tailscale.serve
      assert reparsed.tailscale.serve_port == template.tailscale.serve_port
      assert reparsed.tailscale.serve_target == template.tailscale.serve_target
      assert reparsed.tailscale.routes == template.tailscale.routes
      assert reparsed.tailscale.accept_routes == template.tailscale.accept_routes
      assert reparsed.tailscale.state_dir == template.tailscale.state_dir
    end

    test "special characters roundtrip without corruption" do
      original_xml = read_fixture("special_chars_container.xml")
      {:ok, template} = Template.from_xml(original_xml)
      generated_xml = Template.to_xml(template)
      {:ok, reparsed} = Template.from_xml(generated_xml)

      # Verify special chars are preserved
      secret_orig = Enum.find(template.configs, &(&1.name =~ "Secret"))
      secret_repr = Enum.find(reparsed.configs, &(&1.name =~ "Secret"))
      assert secret_repr.value == secret_orig.value

      json_orig = Enum.find(template.configs, &(&1.name =~ "JSON"))
      json_repr = Enum.find(reparsed.configs, &(&1.name =~ "JSON"))
      assert json_repr.value == json_orig.value

      # Verify paths with spaces
      path_orig = Enum.find(template.configs, &(&1.type == :path))
      path_repr = Enum.find(reparsed.configs, &(&1.type == :path))
      assert path_repr.value == path_orig.value
    end

    test "multiple roundtrips produce stable output" do
      original_xml = read_fixture("complex_container.xml")
      {:ok, t1} = Template.from_xml(original_xml)
      xml1 = Template.to_xml(t1)
      {:ok, t2} = Template.from_xml(xml1)
      xml2 = Template.to_xml(t2)
      {:ok, t3} = Template.from_xml(xml2)
      xml3 = Template.to_xml(t3)

      # After first roundtrip, output should be stable
      assert xml2 == xml3

      # Data should be identical
      assert t2.name == t3.name
      assert t2.repository == t3.repository
      assert length(t2.configs) == length(t3.configs)
    end
  end

  # ---------------------------------------------------------------------------
  # Config Item Helpers
  # ---------------------------------------------------------------------------

  describe "config item helpers" do
    setup do
      {:ok, template} = Template.from_xml(read_fixture("complex_container.xml"))
      %{template: template}
    end

    test "ports/1 filters port configs", %{template: t} do
      ports = Template.ports(t)
      assert Enum.all?(ports, &(&1.type == :port))
    end

    test "paths/1 filters path configs", %{template: t} do
      paths = Template.paths(t)
      assert Enum.all?(paths, &(&1.type == :path))
      assert length(paths) == 3
    end

    test "variables/1 filters variable configs", %{template: t} do
      vars = Template.variables(t)
      assert Enum.all?(vars, &(&1.type == :variable))
      assert length(vars) == 3
    end

    test "devices/1 filters device configs", %{template: t} do
      devices = Template.devices(t)
      assert Enum.all?(devices, &(&1.type == :device))
      assert length(devices) == 1
    end

    test "labels/1 filters label configs", %{template: t} do
      labels = Template.labels(t)
      assert Enum.all?(labels, &(&1.type == :label))
      assert length(labels) == 1
    end
  end

  describe "add_config/2" do
    test "adds a new config item" do
      template = %Template{
        name: "test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      new_config = Template.new_config(:port)
      updated = Template.add_config(template, new_config)

      assert length(updated.configs) == 1
      assert hd(updated.configs).type == :port
    end
  end

  describe "remove_config/2" do
    test "removes config at index" do
      template = %Template{
        name: "test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [
          %{name: "First", type: :port, target: "80", value: "80", default: "", mode: "tcp", display: "always", required: false, mask: false, description: ""},
          %{name: "Second", type: :port, target: "443", value: "443", default: "", mode: "tcp", display: "always", required: false, mask: false, description: ""}
        ],
        tailscale: nil
      }

      updated = Template.remove_config(template, 0)

      assert length(updated.configs) == 1
      assert hd(updated.configs).name == "Second"
    end
  end

  # ---------------------------------------------------------------------------
  # Validation Tests
  # ---------------------------------------------------------------------------

  describe "validate/1" do
    test "returns ok for valid template" do
      template = %Template{
        name: "test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert {:ok, _} = Template.validate(template)
    end

    test "returns error for missing name" do
      template = %Template{
        name: "",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert {:error, errors} = Template.validate(template)
      assert "Container name is required" in errors
    end

    test "returns error for missing repository" do
      template = %Template{
        name: "test",
        repository: "",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert {:error, errors} = Template.validate(template)
      assert "Repository/image is required" in errors
    end

    test "returns error for missing network" do
      template = %Template{
        name: "test",
        repository: "test:latest",
        network: "",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert {:error, errors} = Template.validate(template)
      assert "Network mode is required" in errors
    end
  end

  # ---------------------------------------------------------------------------
  # new_config/1 Tests
  # ---------------------------------------------------------------------------

  describe "new_config/1" do
    test "creates port config with tcp default mode" do
      config = Template.new_config(:port)
      assert config.type == :port
      assert config.mode == "tcp"
    end

    test "creates path config with rw default mode" do
      config = Template.new_config(:path)
      assert config.type == :path
      assert config.mode == "rw"
    end

    test "creates variable config with empty mode" do
      config = Template.new_config(:variable)
      assert config.type == :variable
      assert config.mode == ""
    end
  end
end
