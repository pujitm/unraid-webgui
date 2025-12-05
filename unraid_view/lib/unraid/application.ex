defmodule Unraid.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UnraidWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:unraid, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Unraid.PubSub},
      # Start a worker by calling: Unraid.Worker.start_link(arg)
      # {Unraid.Worker, arg},
      {Unraid.Monitoring.CPUPoller, []},
      # Docker streaming services
      {Unraid.Docker.StatsServer, []},
      {Unraid.Docker.EventsServer, []},
      {Unraid.Docker.TailscaleService, []},
      # Event log system
      {Unraid.EventLog.Writer, []},
      # Terminal session management
      {Registry, keys: :unique, name: Unraid.Terminal.Registry},
      {Unraid.Terminal.TerminalSupervisor, []},
      {Unraid.Terminal.SessionCleanup, []},
      # Start to serve requests, typically the last entry
      UnraidWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Unraid.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UnraidWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
