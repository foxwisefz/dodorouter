defmodule DodoRouter.Logs do
  @moduledoc """
  The Logs context - request logging and analytics.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Routers.Router
  alias DodoRouter.Accounts.User

  # Logging

  def create_log(attrs) do
    result =
      %RequestLog{}
      |> RequestLog.changeset(Map.put(attrs, :inserted_at, DateTime.utc_now()))
      |> Repo.insert()

    case result do
      {:ok, log} ->
        broadcast_log_created(log)
        {:ok, log}

      error ->
        error
    end
  end

  def create_log_async(attrs) do
    Task.start(fn -> create_log(attrs) end)
  end

  defp broadcast_log_created(log) do
    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      "router:#{log.router_id}:logs",
      {:log_created, log}
    )
  end

  def subscribe_to_logs(router_id) do
    Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router_id}:logs")
  end

  def unsubscribe_from_logs(router_id) do
    Phoenix.PubSub.unsubscribe(DodoRouter.PubSub, "router:#{router_id}:logs")
  end

  # Queries

  def list_logs(%Router{} = router, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(l in RequestLog,
      where: l.router_id == ^router.id,
      order_by: [desc: l.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:router]
    )
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_provider(opts[:provider])
    |> maybe_filter_model(opts[:model])
    |> maybe_filter_call_type(opts[:call_type])
    |> maybe_filter_date_range(opts[:from], opts[:to])
    |> Repo.all()
  end

  def list_logs_for_user(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(l in RequestLog,
      join: r in Router,
      on: l.router_id == r.id,
      where: r.user_id == ^user.id,
      order_by: [desc: l.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [router: r]
    )
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_provider(opts[:provider])
    |> maybe_filter_model(opts[:model])
    |> maybe_filter_call_type(opts[:call_type])
    |> maybe_filter_date_range(opts[:from], opts[:to])
    |> Repo.all()
  end

  def get_log!(%User{} = user, id) do
    query =
      from l in RequestLog,
        join: r in Router,
        on: l.router_id == r.id,
        where: l.id == ^id and r.user_id == ^user.id

    Repo.one!(query)
  end

  def get_log_by_request_id(request_id), do: Repo.get_by(RequestLog, request_id: request_id)

  # Analytics

  def stats(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    query =
      from l in RequestLog,
        where: l.router_id == ^router.id and l.inserted_at >= ^since,
        select: %{
          total_requests: count(l.id),
          successful_requests: count(fragment("CASE WHEN ? = 'success' THEN 1 END", l.status)),
          fallback_requests: count(fragment("CASE WHEN ? = 'fallback' THEN 1 END", l.status)),
          error_requests: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
          total_tokens: sum(l.total_tokens),
          prompt_tokens: sum(l.prompt_tokens),
          completion_tokens: sum(l.completion_tokens),
          avg_latency_ms: avg(l.latency_ms),
          total_cost_usd: sum(l.estimated_cost_usd)
        }

    Repo.one(query) || empty_stats()
  end

  def stats_by_provider(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    # Count success + fallback as successful for the final provider (it handled the request)
    from(l in RequestLog,
      where:
        l.router_id == ^router.id and l.inserted_at >= ^since and not is_nil(l.final_provider),
      group_by: l.final_provider,
      select: %{
        provider: l.final_provider,
        total_requests: count(l.id),
        successful_requests:
          count(fragment("CASE WHEN ? IN ('success', 'fallback') THEN 1 END", l.status)),
        error_requests: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
        total_tokens: sum(l.total_tokens),
        avg_latency_ms: avg(l.latency_ms)
      }
    )
    |> Repo.all()
  end

  def stats_by_model(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    # Get all logs and aggregate from attempted_steps to capture all attempts
    logs =
      from(l in RequestLog,
        where: l.router_id == ^router.id and l.inserted_at >= ^since,
        select: l.attempted_steps
      )
      |> Repo.all()

    # Aggregate stats from all attempted steps
    logs
    |> List.flatten()
    |> Enum.group_by(fn step -> {step["provider"], step["model"]} end)
    |> Enum.map(fn {{provider, model}, steps} ->
      successful = Enum.count(steps, &(&1["status"] == "success"))
      total = length(steps)
      latencies = steps |> Enum.map(& &1["latency_ms"]) |> Enum.reject(&is_nil/1)

      avg_latency =
        if length(latencies) > 0, do: Enum.sum(latencies) / length(latencies), else: nil

      %{
        provider: provider,
        model: model,
        total_requests: total,
        successful_requests: successful,
        error_requests: total - successful,
        avg_latency_ms: avg_latency
      }
    end)
  end

  def latency_percentiles(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    query =
      from l in RequestLog,
        where: l.router_id == ^router.id and l.inserted_at >= ^since and not is_nil(l.latency_ms),
        select: %{
          p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", l.latency_ms),
          p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", l.latency_ms),
          p99: fragment("percentile_cont(0.99) WITHIN GROUP (ORDER BY ?)", l.latency_ms)
        }

    Repo.one(query) || %{p50: nil, p95: nil, p99: nil}
  end

  def requests_per_minute(%Router{} = router, opts \\ []) do
    minutes = Keyword.get(opts, :minutes, 60)
    since = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    from(l in RequestLog,
      where: l.router_id == ^router.id and l.inserted_at >= ^since,
      group_by: fragment("date_trunc('minute', ?)", l.inserted_at),
      order_by: fragment("date_trunc('minute', ?)", l.inserted_at),
      select: %{
        minute: fragment("date_trunc('minute', ?)", l.inserted_at),
        count: count(l.id)
      }
    )
    |> Repo.all()
  end

  def failure_breakdown(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    from(l in RequestLog,
      where:
        l.router_id == ^router.id and l.inserted_at >= ^since and
          l.status in ["error", "fallback"],
      group_by: [l.final_provider, l.final_model, l.status],
      order_by: [desc: count(l.id)],
      select: %{
        provider: l.final_provider,
        model: l.final_model,
        status: l.status,
        count: count(l.id)
      }
    )
    |> Repo.all()
  end

  # Private helpers

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [l], l.status == ^status)

  defp maybe_filter_provider(query, nil), do: query

  defp maybe_filter_provider(query, provider),
    do: where(query, [l], l.final_provider == ^provider)

  defp maybe_filter_model(query, nil), do: query
  defp maybe_filter_model(query, model), do: where(query, [l], l.final_model == ^model)

  defp maybe_filter_call_type(query, nil), do: query
  defp maybe_filter_call_type(query, call_type), do: where(query, [l], l.call_type == ^call_type)

  defp maybe_filter_date_range(query, nil, nil), do: query

  defp maybe_filter_date_range(query, from, nil) do
    where(query, [l], l.inserted_at >= ^from)
  end

  defp maybe_filter_date_range(query, nil, to) do
    where(query, [l], l.inserted_at <= ^to)
  end

  defp maybe_filter_date_range(query, from, to) do
    where(query, [l], l.inserted_at >= ^from and l.inserted_at <= ^to)
  end

  defp empty_stats do
    %{
      total_requests: 0,
      successful_requests: 0,
      fallback_requests: 0,
      error_requests: 0,
      total_tokens: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      avg_latency_ms: nil,
      total_cost_usd: nil
    }
  end
end
