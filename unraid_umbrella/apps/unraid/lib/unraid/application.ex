defmodule Unraid.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:unraid, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Unraid.PubSub},
      # Start a worker by calling: Unraid.Worker.start_link(arg)
      # {Unraid.Worker, arg}
      {Registry, keys: :unique, name: Unraid.FileManager.Registry},
      {Unraid.FileManager.Supervisor, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Unraid.Supervisor)
  end
end
