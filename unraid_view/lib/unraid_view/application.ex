defmodule UnraidView.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UnraidViewWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:unraid_view, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Unraid.PubSub},
      # Start a worker by calling: UnraidView.Worker.start_link(arg)
      # {UnraidView.Worker, arg},
      {UnraidView.Monitoring.CPUPoller, []},
      # Docker streaming services
      {Unraid.Docker.StatsServer, []},
      {Unraid.Docker.EventsServer, []},
      # Event log system
      {UnraidView.EventLog.Writer, []},
      # Terminal session management
      {Registry, keys: :unique, name: UnraidView.Terminal.Registry},
      {UnraidView.Terminal.TerminalSupervisor, []},
      # Start to serve requests, typically the last entry
      UnraidViewWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: UnraidView.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UnraidViewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
