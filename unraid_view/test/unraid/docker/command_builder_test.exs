defmodule Unraid.Docker.CommandBuilderTest do
  use ExUnit.Case, async: true

  alias Unraid.Docker.{Template, CommandBuilder}

  @fixtures_path "test/fixtures/templates"

  # ---------------------------------------------------------------------------
  # Basic Command Building
  # ---------------------------------------------------------------------------

  describe "build_create_command/2" do
    test "returns valid command result for minimal template" do
      template = %Template{
        name: "nginx",
        repository: "nginx:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.name == "nginx"
      assert result.repository == "nginx:latest"
      assert is_binary(result.command)
      assert is_list(result.args)
    end

    test "command starts with docker create" do
      template = build_template("test-app", "test:latest")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert String.starts_with?(result.command, "docker create")
    end

    test "command includes container name" do
      template = build_template("my-container", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--name=my-container"
    end

    test "command ends with repository" do
      template = build_template("app", "myrepo/myimage:v1.0")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert String.ends_with?(result.command, "myrepo/myimage:v1.0")
    end

    test "returns error for invalid template" do
      template = %Template{
        name: "",
        repository: "test:latest",
        network: "bridge",
        shell: "sh",
        privileged: false,
        configs: [],
        tailscale: nil
      }

      assert {:error, {:validation_failed, _}} = CommandBuilder.build_create_command(template)
    end
  end

  # ---------------------------------------------------------------------------
  # Network Configuration
  # ---------------------------------------------------------------------------

  describe "network handling" do
    test "includes bridge network" do
      template = build_template("app", "image:tag", network: "bridge")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--net=bridge"
    end

    test "includes host network" do
      template = build_template("app", "image:tag", network: "host")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--net=host"
    end

    test "normalizes network to lowercase" do
      template = build_template("app", "image:tag", network: "BRIDGE")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--net=bridge"
    end

    test "preserves container: prefix for shared network" do
      template = build_template("app", "image:tag", network: "container:other-app")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--net=container:other-app"
    end

    test "includes IP address when specified" do
      template = build_template("app", "image:tag", my_ip: "192.168.1.100")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--ip=192.168.1.100"
    end

    test "includes IPv6 address when specified" do
      template = build_template("app", "image:tag", my_ip: "fd00::1")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--ip6=fd00::1"
    end

    test "handles multiple IP addresses" do
      template = build_template("app", "image:tag", my_ip: "192.168.1.100 fd00::1")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--ip=192.168.1.100"
      assert result.command =~ "--ip6=fd00::1"
    end
  end

  # ---------------------------------------------------------------------------
  # CPU and Resource Limits
  # ---------------------------------------------------------------------------

  describe "resource limits" do
    test "includes cpuset when specified" do
      template = build_template("app", "image:tag", cpuset: "0,1,2-4")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--cpuset-cpus=0,1,2-4"
    end

    test "includes default pid limit" do
      template = build_template("app", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--pids-limit 2048"
    end

    test "respects custom pid limit option" do
      template = build_template("app", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template, pid_limit: 4096)

      assert result.command =~ "--pids-limit 4096"
    end

    test "includes privileged flag when true" do
      template = build_template("app", "image:tag", privileged: true)
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--privileged=true"
    end

    test "excludes privileged flag when false" do
      template = build_template("app", "image:tag", privileged: false)
      {:ok, result} = CommandBuilder.build_create_command(template)

      refute result.command =~ "--privileged"
    end
  end

  # ---------------------------------------------------------------------------
  # Environment Variables
  # ---------------------------------------------------------------------------

  describe "environment variables" do
    test "includes TZ environment variable" do
      template = build_template("app", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template, timezone: "UTC")

      assert result.command =~ ~s(-e TZ="UTC")
    end

    test "includes HOST_* environment variables" do
      template = build_template("app", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template, hostname: "MyServer")

      assert result.command =~ ~s(-e HOST_OS="Unraid")
      assert result.command =~ ~s(-e HOST_HOSTNAME="MyServer")
      assert result.command =~ ~s(-e HOST_CONTAINERNAME="app")
    end

    test "includes user-defined environment variables" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Database URL",
          target: "DATABASE_URL",
          default: "postgres://localhost/db",
          value: "postgres://db.local/mydb",
          mode: "",
          type: :variable,
          display: "always",
          required: true,
          mask: false,
          description: "Database connection"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-e DATABASE_URL="
      assert result.command =~ "postgres://db.local/mydb"
    end

    test "uses default value when value is empty" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "API Key",
          target: "API_KEY",
          default: "default-key",
          value: "",
          mode: "",
          type: :variable,
          display: "always",
          required: false,
          mask: false,
          description: "API key"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-e API_KEY=default-key"
    end
  end

  # ---------------------------------------------------------------------------
  # Port Mappings
  # ---------------------------------------------------------------------------

  describe "port mappings" do
    test "includes port mappings for bridge network" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "HTTP",
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
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-p 8080:80/tcp"
    end

    test "exports ports as env vars for host network" do
      template = build_template("app", "image:tag", network: "host", configs: [
        %{
          name: "HTTP",
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
      ])
      {:ok, result} = CommandBuilder.build_create_command(template, network_drivers: %{"host" => "host"})

      assert result.command =~ "-e TCP_PORT_80=8080"
    end

    test "handles UDP ports" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "DNS",
          target: "53",
          default: "53",
          value: "53",
          mode: "udp",
          type: :port,
          display: "always",
          required: true,
          mask: false,
          description: "DNS port"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-p 53:53/udp"
    end
  end

  # ---------------------------------------------------------------------------
  # Volume Mappings
  # ---------------------------------------------------------------------------

  describe "volume mappings" do
    test "includes volume mappings" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Config",
          target: "/app/config",
          default: "/mnt/user/appdata/app",
          value: "/mnt/user/appdata/app",
          mode: "rw",
          type: :path,
          display: "always",
          required: true,
          mask: false,
          description: "Config directory"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-v /mnt/user/appdata/app:/app/config:rw"
    end

    test "uses default mode rw when mode is empty" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Config",
          target: "/app/config",
          default: "/mnt/appdata",
          value: "/mnt/appdata",
          mode: "",
          type: :path,
          display: "always",
          required: true,
          mask: false,
          description: "Config"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-v /mnt/appdata:/app/config:rw"
    end

    test "handles read-only volumes" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Media",
          target: "/media",
          default: "/mnt/user/media",
          value: "/mnt/user/media",
          mode: "ro",
          type: :path,
          display: "always",
          required: true,
          mask: false,
          description: "Media"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-v /mnt/user/media:/media:ro"
    end
  end

  # ---------------------------------------------------------------------------
  # Labels
  # ---------------------------------------------------------------------------

  describe "labels" do
    test "includes standard managed label" do
      template = build_template("app", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-l net.unraid.docker.managed=dockerman"
    end

    test "includes webui label when specified" do
      template = build_template("app", "image:tag", web_ui: "http://[IP]:[PORT:8080]/")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-l net.unraid.docker.webui="
    end

    test "includes icon label when specified" do
      template = build_template("app", "image:tag", icon: "https://example.com/icon.png")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-l net.unraid.docker.icon="
    end

    test "includes user-defined labels" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Custom Label",
          target: "com.example.label",
          default: "",
          value: "my-value",
          mode: "",
          type: :label,
          display: "always",
          required: false,
          mask: false,
          description: "Custom label"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-l com.example.label=my-value"
    end
  end

  # ---------------------------------------------------------------------------
  # Devices
  # ---------------------------------------------------------------------------

  describe "devices" do
    test "includes device mappings" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "GPU",
          target: "/dev/dri",
          default: "/dev/dri",
          value: "/dev/dri",
          mode: "",
          type: :device,
          display: "advanced",
          required: false,
          mask: false,
          description: "GPU device"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--device=/dev/dri"
    end
  end

  # ---------------------------------------------------------------------------
  # Extra Params and Post Args
  # ---------------------------------------------------------------------------

  describe "extra params" do
    test "includes extra params" do
      template = build_template("app", "image:tag", extra_params: "--memory=4g --restart=unless-stopped")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--memory=4g --restart=unless-stopped"
    end

    test "does not duplicate network if specified in extra params" do
      template = build_template("app", "image:tag",
        network: "bridge",
        extra_params: "--network=custom-net"
      )
      {:ok, result} = CommandBuilder.build_create_command(template)

      # Should not have --net=bridge since extra_params has --network
      refute result.command =~ "--net=bridge"
      assert result.command =~ "--network=custom-net"
    end

    test "does not duplicate pid limit if specified in extra params" do
      template = build_template("app", "image:tag", extra_params: "--pids-limit 1000")
      {:ok, result} = CommandBuilder.build_create_command(template)

      # Should only have the one from extra_params
      assert result.command =~ "--pids-limit 1000"
      refute result.command =~ "--pids-limit 2048"
    end
  end

  describe "post args" do
    test "includes post args at end of command" do
      template = build_template("app", "image:tag", post_args: "--config=/path/to/config")
      {:ok, result} = CommandBuilder.build_create_command(template)

      # Post args should come after the repository
      assert String.ends_with?(result.command, "--config=/path/to/config")
    end
  end

  # ---------------------------------------------------------------------------
  # Shell Escaping
  # ---------------------------------------------------------------------------

  describe "shell escaping" do
    test "escapes container names with spaces" do
      template = build_template("my app", "image:tag")
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--name='my app'"
    end

    test "escapes values with special characters" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Password",
          target: "PASSWORD",
          default: "",
          value: "p@$$w0rd!&more",
          mode: "",
          type: :variable,
          display: "always",
          required: true,
          mask: true,
          description: "Password"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "-e PASSWORD='p@$$w0rd!&more'"
    end

    test "escapes paths with spaces" do
      template = build_template("app", "image:tag", configs: [
        %{
          name: "Config",
          target: "/app/config",
          default: "",
          value: "/mnt/user/My App Data/config",
          mode: "rw",
          type: :path,
          display: "always",
          required: true,
          mask: false,
          description: "Config"
        }
      ])
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "'/mnt/user/My App Data/config'"
    end
  end

  # ---------------------------------------------------------------------------
  # Tailscale Integration
  # ---------------------------------------------------------------------------

  describe "tailscale integration" do
    test "includes tailscale env vars when enabled" do
      template = build_template("app", "image:tag",
        tailscale: %{
          enabled: true,
          hostname: "my-app",
          is_exit_node: false,
          exit_node_ip: nil,
          ssh: "true",
          userspace_networking: "false",
          lan_access: "true",
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
          state_dir: "/data/ts",
          troubleshooting: false
        }
      )
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "TAILSCALE_HOSTNAME="
      assert result.command =~ "TAILSCALE_STATE_DIR="
    end

    test "includes tun device for tailscale when required" do
      template = build_template("app", "image:tag",
        tailscale: %{
          enabled: true,
          hostname: "my-app",
          is_exit_node: false,
          exit_node_ip: nil,
          ssh: "true",
          userspace_networking: "false",  # Kernel networking requires tun
          lan_access: "true",
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
          state_dir: "/data/ts",
          troubleshooting: false
        }
      )
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.command =~ "--device='/dev/net/tun'"
      assert result.command =~ "--cap-add=NET_ADMIN"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture Integration Tests
  # ---------------------------------------------------------------------------

  describe "fixture roundtrip" do
    test "generates valid command for simple container fixture" do
      path = Path.join(@fixtures_path, "simple_container.xml")
      {:ok, xml} = File.read(path)
      {:ok, template} = Template.from_xml(xml)
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.name == template.name
      assert result.repository == template.repository
      assert result.command =~ "--name=#{template.name}"
      assert result.command =~ template.repository
    end

    test "generates valid command for complex container fixture" do
      path = Path.join(@fixtures_path, "complex_container.xml")
      {:ok, xml} = File.read(path)
      {:ok, template} = Template.from_xml(xml)
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.name == "plex"
      assert result.command =~ "--cpuset-cpus=0,1,2,3"
      assert result.command =~ "--memory=4g"
      assert result.command =~ "-v /mnt/user/appdata/plex:/config:rw"
      assert result.command =~ "--device=/dev/dri"
    end

    test "generates valid command for tailscale container fixture" do
      path = Path.join(@fixtures_path, "tailscale_container.xml")
      {:ok, xml} = File.read(path)
      {:ok, template} = Template.from_xml(xml)
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.name == "pihole-ts"
      assert result.command =~ "TAILSCALE_HOSTNAME="
      assert result.command =~ "TAILSCALE_STATE_DIR="
    end

    test "generates valid command for special chars container fixture" do
      path = Path.join(@fixtures_path, "special_chars_container.xml")
      {:ok, xml} = File.read(path)
      {:ok, template} = Template.from_xml(xml)
      {:ok, result} = CommandBuilder.build_create_command(template)

      assert result.name == "special-app"
      # Paths with spaces should be escaped
      assert result.command =~ "'/mnt/user/appdata/special app'"
      # Special chars in values should be escaped
      assert result.command =~ "p@$$w0rd!&more"
    end
  end

  # ---------------------------------------------------------------------------
  # Build Args Helper
  # ---------------------------------------------------------------------------

  describe "build_args/2" do
    test "returns list of argument strings" do
      template = build_template("app", "image:tag")
      args = CommandBuilder.build_args(template)

      assert is_list(args)
      assert "docker create" in args
      assert "--name=app" in args
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_template(name, repository, opts \\ []) do
    %Template{
      name: name,
      repository: repository,
      network: Keyword.get(opts, :network, "bridge"),
      shell: Keyword.get(opts, :shell, "sh"),
      privileged: Keyword.get(opts, :privileged, false),
      my_ip: Keyword.get(opts, :my_ip),
      cpuset: Keyword.get(opts, :cpuset),
      extra_params: Keyword.get(opts, :extra_params),
      post_args: Keyword.get(opts, :post_args),
      web_ui: Keyword.get(opts, :web_ui),
      icon: Keyword.get(opts, :icon),
      configs: Keyword.get(opts, :configs, []),
      tailscale: Keyword.get(opts, :tailscale)
    }
  end
end
