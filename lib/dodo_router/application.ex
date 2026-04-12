defmodule DodoRouter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DodoRouter.ShutdownListener,
      DodoRouterWeb.Telemetry,
      DodoRouter.Repo,
      {DNSCluster, query: Application.get_env(:dodo_router, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DodoRouter.PubSub},
      DodoRouter.Proxy.InflightTracker,
      # Start to serve requests, typically the last entry
      DodoRouterWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DodoRouter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DodoRouterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
