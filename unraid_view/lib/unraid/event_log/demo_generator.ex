defmodule Unraid.EventLog.DemoGenerator do
  @moduledoc """
  Generates mock events for demonstration and testing.

  Each demo function creates events that showcase different aspects of the
  event log system, including progress updates, link additions, child events,
  and various statuses.
  """

  alias Unraid.EventLog

  @container_names ~w(nginx redis postgres grafana prometheus elasticsearch kibana rabbitmq mongodb mysql)
  @container_actions ~w(start stop restart pause unpause)

  @doc """
  Generates a random Docker container event.
  """
  def generate_docker_event do
    container = Enum.random(@container_names)
    action = Enum.random(@container_actions)

    EventLog.emit(%{
      source: "docker",
      category: "container.#{action}",
      summary: "Container '#{container}' #{action}ed",
      severity: :info,
      status: :completed,
      metadata: %{
        container_id: random_hex(12),
        container_name: container,
        image: "#{container}:latest"
      }
    })
  end

  @doc """
  Starts a mock build task that progresses over time and adds log links.

  This demonstrates:
  - Running tasks with progress updates
  - Links being added over time
  - Child events for sub-tasks
  """
  def start_build_task do
    {:ok, parent} =
      EventLog.emit(%{
        source: "system",
        category: "build.container",
        summary: "Building custom container image",
        severity: :notice,
        status: :running,
        progress: 0,
        metadata: %{
          image_name: "custom-app",
          dockerfile: "/mnt/user/appdata/custom-app/Dockerfile"
        }
      })

    # Run the mock build in a separate process
    Task.start(fn ->
      run_build_task(parent.id)
    end)

    {:ok, parent}
  end

  defp run_build_task(parent_id) do
    phases = [
      {10, "Pulling base image", "pull.log"},
      {30, "Installing dependencies", "deps.log"},
      {60, "Compiling application", "compile.log"},
      {80, "Running tests", "test.log"},
      {95, "Creating image layers", "layers.log"}
    ]

    Enum.each(phases, fn {progress, phase_name, log_file} ->
      # Add child event for this phase
      EventLog.emit(%{
        source: "system",
        category: "build.phase",
        summary: phase_name,
        severity: :info,
        status: :running,
        parent_id: parent_id
      })

      # Simulate some work
      Process.sleep(800 + :rand.uniform(400))

      # Update parent progress
      EventLog.update(parent_id, %{progress: progress})

      # Add log link
      EventLog.add_link(parent_id, %{
        type: :log_file,
        label: phase_name,
        target: "/tmp/build/#{log_file}",
        tailable: false
      })

      # Mark child phase as completed
      # (In a real system, we'd track child IDs)
      Process.sleep(200)
    end)

    # Complete the build
    Process.sleep(500)
    EventLog.update(parent_id, %{status: :completed, progress: 100})
  end

  @doc """
  Starts a mock parity check that shows progress over time.

  This demonstrates:
  - Long-running tasks with gradual progress
  - Status updates
  """
  def start_parity_check do
    {:ok, parent} =
      EventLog.emit(%{
        source: "array",
        category: "parity.check",
        summary: "Parity check started",
        severity: :notice,
        status: :running,
        progress: 0,
        metadata: %{
          parity_disks: 2,
          data_disks: 8,
          total_size_tb: 64
        }
      })

    # Add initial log link
    EventLog.add_link(parent.id, %{
      type: :log_file,
      label: "Parity check log",
      target: "/var/log/parity_check.log",
      tailable: true
    })

    # Run the mock parity check in a separate process
    Task.start(fn ->
      run_parity_check(parent.id)
    end)

    {:ok, parent}
  end

  defp run_parity_check(parent_id) do
    # Simulate gradual progress
    for progress <- 1..20 do
      Process.sleep(300 + :rand.uniform(200))
      EventLog.update(parent_id, %{progress: progress * 5})

      # Occasionally add disk-specific events
      if rem(progress, 5) == 0 do
        disk_num = div(progress, 5)

        EventLog.emit(%{
          source: "array",
          category: "parity.disk_check",
          summary: "Disk #{disk_num} verification complete",
          severity: :info,
          status: :completed,
          parent_id: parent_id,
          metadata: %{
            disk_number: disk_num,
            sectors_checked: :rand.uniform(1_000_000_000),
            errors_found: 0
          }
        })
      end
    end

    # Complete the parity check
    EventLog.update(parent_id, %{status: :completed, progress: 100})
  end

  @doc """
  Generates a system warning event.
  """
  def generate_system_warning do
    warnings = [
      {"High CPU temperature detected", %{temp_c: 85, threshold_c: 80, cpu: "CPU 0"}},
      {"Disk space running low", %{mount: "/mnt/cache", used_percent: 92, free_gb: 12}},
      {"Memory usage above threshold", %{used_percent: 88, available_gb: 4}},
      {"Network interface errors detected", %{interface: "eth0", errors: 127}},
      {"UPS battery low", %{battery_percent: 15, runtime_min: 8}}
    ]

    {summary, metadata} = Enum.random(warnings)

    EventLog.emit(%{
      source: "system",
      category: "monitoring.warning",
      summary: summary,
      severity: :warning,
      status: :completed,
      metadata: metadata
    })
  end

  @doc """
  Generates a failed task event.
  """
  def generate_failed_task do
    failures = [
      {
        "Docker pull failed: registry timeout",
        "docker",
        "pull.failed",
        %{image: "custom/app:latest", error: "connection timeout after 30s"}
      },
      {
        "VM snapshot failed: insufficient space",
        "vm",
        "snapshot.failed",
        %{vm_name: "Windows 10", required_gb: 50, available_gb: 12}
      },
      {
        "Backup job failed: network unreachable",
        "system",
        "backup.failed",
        %{target: "192.168.1.100", share: "backups", error: "host unreachable"}
      },
      {
        "Plugin update failed: dependency conflict",
        "system",
        "plugin.update_failed",
        %{plugin: "community.applications", error: "requires unraid >= 7.0"}
      }
    ]

    {summary, source, category, metadata} = Enum.random(failures)

    {:ok, event} =
      EventLog.emit(%{
        source: source,
        category: category,
        summary: summary,
        severity: :error,
        status: :failed,
        metadata: metadata
      })

    # Add error log link
    EventLog.add_link(event.id, %{
      type: :log_file,
      label: "Error details",
      target: "/var/log/error_#{event.id}.log",
      tailable: false
    })

    {:ok, event}
  end

  @doc """
  Generates a random system event.
  """
  def generate_system_event do
    events = [
      {"User logged in via SSH", :info, %{user: "root", ip: "192.168.1.#{:rand.uniform(254)}"}},
      {"Scheduled backup completed", :info, %{files: :rand.uniform(10000), size_mb: :rand.uniform(5000)}},
      {"Cache pool scrub completed", :notice, %{errors: 0, repaired: 0}},
      {"Docker image pruned", :info, %{reclaimed_mb: :rand.uniform(2000)}}
    ]

    {summary, severity, metadata} = Enum.random(events)

    EventLog.emit(%{
      source: "system",
      category: "event",
      summary: summary,
      severity: severity,
      status: :completed,
      metadata: metadata
    })
  end

  # Helper

  defp random_hex(length) do
    :crypto.strong_rand_bytes(div(length, 2))
    |> Base.encode16(case: :lower)
    |> String.slice(0, length)
  end
end
