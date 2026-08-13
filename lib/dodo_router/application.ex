defmodule DodoRouter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach Finch telemetry handlers for request timing
    DodoRouter.Proxy.FinchTelemetry.attach()

    # attesto's Ecto stores resolve config from their own app env and fall back
    # to an EMPTY config when it is absent — which fails late and vaguely rather
    # than at boot. Publishing the resolved struct once removes that whole class.
    Application.put_env(:attesto_phoenix, :config, DodoRouter.AuthZ.server_config())

    # Own the secrets cache table from a process that lives as long as the
    # app — created lazily it belongs to the first process that touches it
    # and vanishes (with all cached secrets) when that process exits.
    DodoRouter.Secrets.init_cache()

    children = [
      DodoRouter.ShutdownListener,
      DodoRouterWeb.Telemetry,
      DodoRouter.Repo,
      {DNSCluster, query: Application.get_env(:dodo_router, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DodoRouter.PubSub},
      {Task.Supervisor, name: DodoRouter.KeyHealthTaskSupervisor},
      {Task.Supervisor, name: DodoRouter.EvaluationTaskSupervisor},
      # Tracks live benchmark processes; the entry dying with its process is
      # what lets evaluations recover from a restart mid-benchmark.
      {Registry, keys: :unique, name: DodoRouter.EvaluationRegistry},
      DodoRouter.Activity,
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
