defmodule Unraid.Docker.TemplateAdapterTest do
  use ExUnit.Case, async: true

  alias Unraid.Docker.{Template, TemplateAdapter}

  @fixtures_path "test/fixtures/templates"

  # Use a temp directory for write tests to avoid polluting fixtures
  setup do
    temp_dir = System.tmp_dir!() |> Path.join("unraid_template_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(temp_dir)

    # Store original config
    original_path = Application.get_env(:unraid, :docker_templates_path)

    # Set temp dir as templates path
    Application.put_env(:unraid, :docker_templates_path, temp_dir)

    on_exit(fn ->
      # Cleanup
      File.rm_rf!(temp_dir)
      # Restore original config
      if original_path do
        Application.put_env(:unraid, :docker_templates_path, original_path)
      else
        Application.delete_env(:unraid, :docker_templates_path)
      end
    end)

    %{temp_dir: temp_dir}
  end

  # ---------------------------------------------------------------------------
  # Read Operations
  # ---------------------------------------------------------------------------

  describe "read_template_from_path/1" do
    test "reads and parses a valid XML template" do
      path = Path.join(@fixtures_path, "simple_container.xml")
      {:ok, template} = TemplateAdapter.read_template_from_path(path)

      assert template.name == "nginx"
      assert template.repository == "nginx:latest"
    end

    test "reads complex template with all config types" do
      path = Path.join(@fixtures_path, "complex_container.xml")
      {:ok, template} = TemplateAdapter.read_template_from_path(path)

      assert template.name == "plex"
      assert length(template.configs) == 8
    end

    test "reads template with Tailscale settings" do
      path = Path.join(@fixtures_path, "tailscale_container.xml")
      {:ok, template} = TemplateAdapter.read_template_from_path(path)

      assert template.tailscale != nil
      assert template.tailscale.enabled == true
      assert template.tailscale.hostname == "pihole-server"
    end

    test "returns error for non-existent file" do
      path = "/nonexistent/path/template.xml"
      assert {:error, {:file_read_error, :enoent, ^path}} = TemplateAdapter.read_template_from_path(path)
    end

    @tag :capture_log
    test "returns error for invalid XML" do
      # Create a temp file with invalid XML
      temp_file = Path.join(System.tmp_dir!(), "invalid_#{:rand.uniform(100_000)}.xml")
      File.write!(temp_file, "not valid xml <<<<")

      result = TemplateAdapter.read_template_from_path(temp_file)
      assert {:error, _} = result

      File.rm!(temp_file)
    end
  end

  # ---------------------------------------------------------------------------
  # Write Operations
  # ---------------------------------------------------------------------------

  describe "write_template/1" do
    test "writes a valid template to file", %{temp_dir: temp_dir} do
      template = %Template{
        name: "test-container",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert :ok = TemplateAdapter.write_template(template)

      # Verify file was created
      expected_path = Path.join(temp_dir, "my-test-container.xml")
      assert File.exists?(expected_path)

      # Verify content is valid XML that can be parsed back
      {:ok, reparsed} = TemplateAdapter.read_template_from_path(expected_path)
      assert reparsed.name == "test-container"
      assert reparsed.repository == "test:latest"
    end

    test "writes template with configs", %{temp_dir: temp_dir} do
      template = %Template{
        name: "with-configs",
        repository: "nginx:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [
          %{
            name: "HTTP Port",
            target: "80",
            default: "8080",
            value: "8080",
            mode: "tcp",
            type: :port,
            display: "always",
            required: true,
            mask: false,
            description: "Web port"
          },
          %{
            name: "Config Path",
            target: "/etc/nginx",
            default: "/mnt/appdata/nginx",
            value: "/mnt/appdata/nginx",
            mode: "rw",
            type: :path,
            display: "always",
            required: true,
            mask: false,
            description: "Config directory"
          }
        ],
        tailscale: nil
      }

      assert :ok = TemplateAdapter.write_template(template)

      # Read back and verify
      expected_path = Path.join(temp_dir, "my-with-configs.xml")
      {:ok, reparsed} = TemplateAdapter.read_template_from_path(expected_path)

      assert length(reparsed.configs) == 2
      assert Enum.any?(reparsed.configs, &(&1.type == :port))
      assert Enum.any?(reparsed.configs, &(&1.type == :path))
    end

    test "writes template with Tailscale settings", %{temp_dir: temp_dir} do
      template = %Template{
        name: "ts-container",
        repository: "app:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: %{
          enabled: true,
          hostname: "my-app",
          is_exit_node: false,
          exit_node_ip: nil,
          ssh: "true",
          userspace_networking: "false",
          lan_access: "true",
          serve: "funnel",
          serve_port: "443",
          serve_target: "http://localhost:8080",
          serve_local_path: nil,
          serve_protocol: nil,
          serve_protocol_port: nil,
          serve_path: nil,
          web_ui: "https://[hostname]/",
          routes: "10.0.0.0/8",
          accept_routes: true,
          daemon_params: nil,
          extra_params: nil,
          state_dir: "/data/ts",
          troubleshooting: false
        }
      }

      assert :ok = TemplateAdapter.write_template(template)

      # Read back and verify
      expected_path = Path.join(temp_dir, "my-ts-container.xml")
      {:ok, reparsed} = TemplateAdapter.read_template_from_path(expected_path)

      assert reparsed.tailscale.enabled == true
      assert reparsed.tailscale.hostname == "my-app"
      assert reparsed.tailscale.serve == "funnel"
      assert reparsed.tailscale.routes == "10.0.0.0/8"
    end

    test "returns validation error for invalid template" do
      template = %Template{
        name: "",  # Invalid - empty name
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert {:error, {:validation_failed, errors}} = TemplateAdapter.write_template(template)
      assert "Container name is required" in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Roundtrip File Tests - Critical for data integrity
  # ---------------------------------------------------------------------------

  describe "file roundtrip" do
    test "write then read preserves all simple container data", %{temp_dir: _} do
      # Read fixture
      fixture_path = Path.join(@fixtures_path, "simple_container.xml")
      {:ok, original} = TemplateAdapter.read_template_from_path(fixture_path)

      # Write to temp
      assert :ok = TemplateAdapter.write_template(original)

      # Read back
      {:ok, roundtripped} = TemplateAdapter.read_template(original.name)

      # Compare
      assert roundtripped.name == original.name
      assert roundtripped.repository == original.repository
      assert roundtripped.network == original.network
      assert roundtripped.web_ui == original.web_ui
      assert length(roundtripped.configs) == length(original.configs)
    end

    test "write then read preserves complex container data", %{temp_dir: _} do
      fixture_path = Path.join(@fixtures_path, "complex_container.xml")
      {:ok, original} = TemplateAdapter.read_template_from_path(fixture_path)

      assert :ok = TemplateAdapter.write_template(original)
      {:ok, roundtripped} = TemplateAdapter.read_template(original.name)

      assert roundtripped.cpuset == original.cpuset
      assert roundtripped.extra_params == original.extra_params

      # Check all config types preserved
      for type <- [:port, :path, :variable, :device, :label] do
        orig_count = Enum.count(original.configs, &(&1.type == type))
        round_count = Enum.count(roundtripped.configs, &(&1.type == type))
        assert round_count == orig_count, "Config type #{type} count mismatch"
      end
    end

    test "write then read preserves Tailscale container data", %{temp_dir: _} do
      fixture_path = Path.join(@fixtures_path, "tailscale_container.xml")
      {:ok, original} = TemplateAdapter.read_template_from_path(fixture_path)

      assert :ok = TemplateAdapter.write_template(original)
      {:ok, roundtripped} = TemplateAdapter.read_template(original.name)

      assert roundtripped.tailscale.enabled == original.tailscale.enabled
      assert roundtripped.tailscale.hostname == original.tailscale.hostname
      assert roundtripped.tailscale.serve == original.tailscale.serve
      assert roundtripped.tailscale.serve_port == original.tailscale.serve_port
      assert roundtripped.tailscale.routes == original.tailscale.routes
      assert roundtripped.tailscale.state_dir == original.tailscale.state_dir
    end

    test "write then read preserves special characters", %{temp_dir: _} do
      fixture_path = Path.join(@fixtures_path, "special_chars_container.xml")
      {:ok, original} = TemplateAdapter.read_template_from_path(fixture_path)

      assert :ok = TemplateAdapter.write_template(original)
      {:ok, roundtripped} = TemplateAdapter.read_template(original.name)

      # Find configs with special chars
      secret_orig = Enum.find(original.configs, &(&1.name =~ "Secret"))
      secret_round = Enum.find(roundtripped.configs, &(&1.name =~ "Secret"))
      assert secret_round.value == secret_orig.value

      json_orig = Enum.find(original.configs, &(&1.name =~ "JSON"))
      json_round = Enum.find(roundtripped.configs, &(&1.name =~ "JSON"))
      assert json_round.value == json_orig.value
    end
  end

  # ---------------------------------------------------------------------------
  # Template Existence and Deletion
  # ---------------------------------------------------------------------------

  describe "template_exists?/1" do
    test "returns false for non-existent template" do
      refute TemplateAdapter.template_exists?("nonexistent-container")
    end

    test "returns true after writing template", %{temp_dir: _} do
      template = %Template{
        name: "exists-test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      refute TemplateAdapter.template_exists?("exists-test")
      assert :ok = TemplateAdapter.write_template(template)
      assert TemplateAdapter.template_exists?("exists-test")
    end
  end

  describe "delete_template/1" do
    test "deletes existing template", %{temp_dir: _} do
      template = %Template{
        name: "to-delete",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert :ok = TemplateAdapter.write_template(template)
      assert TemplateAdapter.template_exists?("to-delete")

      assert :ok = TemplateAdapter.delete_template("to-delete")
      refute TemplateAdapter.template_exists?("to-delete")
    end

    test "returns error for non-existent template" do
      assert {:error, :not_found} = TemplateAdapter.delete_template("nonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # List Templates
  # ---------------------------------------------------------------------------

  describe "list_templates/0" do
    test "returns empty list when no templates", %{temp_dir: _} do
      assert [] = TemplateAdapter.list_templates()
    end

    test "returns list of templates", %{temp_dir: _} do
      for name <- ["app1", "app2", "app3"] do
        template = %Template{
          name: name,
          repository: "test:latest",
          network: "bridge",
          shell: "sh",
          privileged: false,
          configs: [],
          tailscale: nil
        }
        :ok = TemplateAdapter.write_template(template)
      end

      templates = TemplateAdapter.list_templates()
      assert length(templates) == 3

      names = Enum.map(templates, fn {name, _path} -> name end)
      assert "app1" in names
      assert "app2" in names
      assert "app3" in names
    end
  end

  # ---------------------------------------------------------------------------
  # Extract Container Name
  # ---------------------------------------------------------------------------

  describe "extract_container_name/1" do
    test "extracts name from standard filename" do
      assert "nginx" == TemplateAdapter.extract_container_name("my-nginx.xml")
    end

    test "handles names with hyphens" do
      assert "my-cool-app" == TemplateAdapter.extract_container_name("my-my-cool-app.xml")
    end

    test "handles names without my- prefix" do
      # When there's no "my-" prefix, it just strips ".xml" extension
      assert "app" == TemplateAdapter.extract_container_name("app.xml")
    end
  end

  # ---------------------------------------------------------------------------
  # Template Path
  # ---------------------------------------------------------------------------

  describe "template_path/1" do
    test "generates correct path", %{temp_dir: temp_dir} do
      path = TemplateAdapter.template_path("nginx")
      assert path == Path.join(temp_dir, "my-nginx.xml")
    end
  end

  # ---------------------------------------------------------------------------
  # Backup Template
  # ---------------------------------------------------------------------------

  describe "backup_template/1" do
    test "creates backup of existing template", %{temp_dir: temp_dir} do
      template = %Template{
        name: "backup-test",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      :ok = TemplateAdapter.write_template(template)
      {:ok, backup_path} = TemplateAdapter.backup_template("backup-test")

      assert String.starts_with?(backup_path, temp_dir)
      assert backup_path =~ ".backup."
      assert File.exists?(backup_path)

      # Original should still exist
      assert TemplateAdapter.template_exists?("backup-test")

      # Backup should contain same data
      {:ok, backup_content} = File.read(backup_path)
      {:ok, backup_template} = Template.from_xml(backup_content)
      assert backup_template.name == "backup-test"
    end
  end
end
