defmodule Meridian.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MeridianWeb.Telemetry,
      Meridian.Repo,
      {DNSCluster, query: Application.get_env(:meridian, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Meridian.PubSub},
      Meridian.Upstream.ModelCache,
      # Extension hook handlers run here. Before the run supervisor, so it outlives the runs on
      # shutdown (an interrupted run still fires run_end).
      {Task.Supervisor, name: Meridian.Extensions.TaskSupervisor},
      {Registry, keys: :unique, name: Meridian.Runs.Registry},
      {DynamicSupervisor, name: Meridian.Runs.Supervisor, strategy: :one_for_one},
      # After the run supervisor, so on shutdown Oban stops (and stops taking runs) first.
      {Oban, Application.fetch_env!(:meridian, Oban)},
      # Start to serve requests, typically the last entry
      MeridianWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Meridian.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MeridianWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
