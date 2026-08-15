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
      # Keeps the model catalog current. Prices from this table are what
      # list_cost_usd is computed from, so a stale catalog is wrong money
      # rather than a cosmetic problem.
      {DodoRouter.Models.SyncScheduler, []},
      # Start to serve requests, typically the last entry
      DodoRouterWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DodoRouter.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      recover_interrupted_benchmarks()
      {:ok, pid}
    end
  end

  # A benchmark lives in a task, so a restart orphans whatever it had in
  # flight: runs stuck at "running" that no process will finish, and an
  # evaluation stuck at "running" that can never run again. Boot is the one
  # moment nothing can be executing, so it is when we say so.
  #
  # Skipped under the SQL sandbox: at boot a test process owns no connection
  # to borrow, and the fixtures each test builds are not this function's to
  # rewrite. `evaluations_recovery_test.exs` calls it directly instead.
  defp recover_interrupted_benchmarks do
    unless Application.get_env(:dodo_router, :sql_sandbox, false) do
      case DodoRouter.Evaluations.recover_interrupted() do
        {0, 0} ->
          :ok

        {runs, evaluations} ->
          require Logger

          Logger.info(
            "Recovered #{runs} interrupted evaluation run(s) across #{evaluations} evaluation(s)"
          )
      end
    end
  rescue
    # Never let housekeeping stop the app from booting.
    exception ->
      require Logger
      Logger.error("Benchmark recovery failed: #{Exception.message(exception)}")
      :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DodoRouterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
