defmodule Switchboard.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    SwitchboardWeb.RequestLog.attach()
    Switchboard.Repo.QueryLog.attach()

    children = [
      SwitchboardWeb.Telemetry,
      Switchboard.Repo,
      {DNSCluster, query: Application.get_env(:switchboard, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Switchboard.PubSub},
      Switchboard.Vault,
      Switchboard.RateLimit,
      Switchboard.Upstreams.Guard,
      Switchboard.Cache,
      {Task.Supervisor, name: Switchboard.TaskSupervisor},
      {Oban, Application.fetch_env!(:switchboard, Oban)},
      {Switchboard.MCP.Server,
       transport: {:streamable_http, start: true, keepalive_interval: 15_000}},
      # Start to serve requests, typically the last entry
      SwitchboardWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Switchboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SwitchboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
