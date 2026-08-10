defmodule DodoRouter.Logs do
  @moduledoc """
  The Logs context - request logging and analytics.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Routers.Router
  alias DodoRouter.Accounts.User
  alias DodoRouter.Usage

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
    DodoRouter.BackgroundTask.start(fn -> create_log(attrs) end)
  end

  defp broadcast_log_created(log) do
    # Preload router for display in live view
    log = Repo.preload(log, :router)

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
      where: l.router_id == ^router.id and l.traffic_type == "proxy",
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
    |> maybe_filter_favorite(opts[:favorites_only])
    |> Repo.all()
  end

  def list_logs_for_user(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(l in RequestLog,
      join: r in Router,
      on: l.router_id == r.id,
      where: r.user_id == ^user.id and l.traffic_type == "proxy",
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
    |> maybe_filter_favorite(opts[:favorites_only])
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

  def get_log(%User{} = user, id) do
    query =
      from l in RequestLog,
        join: r in Router,
        on: l.router_id == r.id,
        where: l.id == ^id and r.user_id == ^user.id

    Repo.one(query)
  end

  def get_log_by_request_id!(user, request_id) do
    case get_log_by_request_id(user, request_id) do
      nil -> raise Ecto.NoResultsError, queryable: RequestLog
      log -> log
    end
  end

  def get_log_by_request_id(%User{} = user, request_id) do
    query =
      from l in RequestLog,
        join: r in Router,
        on: l.router_id == r.id,
        where: l.request_id == ^request_id and r.user_id == ^user.id

    Repo.one(query)
  end

  def get_log_by_request_id(request_id), do: Repo.get_by(RequestLog, request_id: request_id)

  @doc """
  Lists logs produced by replaying the given log, oldest first.
  """
  def list_replays(%RequestLog{id: id}) do
    from(l in RequestLog,
      where: l.replayed_from_id == ^id,
      order_by: [asc: l.inserted_at],
      preload: [:router]
    )
    |> Repo.all()
  end

  @doc """
  Lean per-log response info for a session, oldest first — enough for
  `Logs.Provenance` matching without loading request bodies.
  """
  def list_session_responses(%User{} = user, session_id) do
    from(l in RequestLog,
      join: r in Router,
      on: l.router_id == r.id,
      where: l.session_id == ^session_id and r.user_id == ^user.id,
      order_by: [asc: l.inserted_at],
      select: %{
        id: l.id,
        final_provider: l.final_provider,
        final_model: l.final_model,
        response_body: l.response_body,
        inserted_at: l.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Map of log id => number of replays, for the given log ids.
  Ids without replays are absent from the result.
  """
  def replay_counts(log_ids) when is_list(log_ids) do
    from(l in RequestLog,
      where: l.replayed_from_id in ^log_ids,
      group_by: l.replayed_from_id,
      select: {l.replayed_from_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Chains can't realistically get deep, but a cycle or corrupt data must
  # not loop forever
  @max_replay_depth 20

  @doc """
  Walks `replayed_from_id` up to the original log the given one descends
  from. Returns the log itself when it isn't a replay.
  """
  def root_of(%RequestLog{} = log), do: walk_to_root(log, @max_replay_depth)

  defp walk_to_root(%RequestLog{replayed_from_id: nil} = log, _depth), do: log
  defp walk_to_root(log, 0), do: log

  defp walk_to_root(%RequestLog{replayed_from_id: parent_id} = log, depth) do
    case Repo.get(RequestLog, parent_id) do
      nil -> log
      parent -> walk_to_root(parent, depth - 1)
    end
  end

  def toggle_favorite(%User{} = user, id_or_request_id) do
    log = get_log(user, id_or_request_id) || get_log_by_request_id(user, id_or_request_id)

    if log do
      log
      |> Ecto.Changeset.change(favorite: !log.favorite)
      |> Repo.update()
    else
      {:error, :not_found}
    end
  end

  # Public sharing

  # Analytics

  def stats(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    query =
      from l in RequestLog,
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and
            l.traffic_type == "proxy",
        select: %{
          total_requests: count(l.id),
          successful_requests:
            count(fragment("CASE WHEN ? IN ('success', 'fallback') THEN 1 END", l.status)),
          fallback_requests: count(fragment("CASE WHEN ? = 'fallback' THEN 1 END", l.status)),
          error_requests: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
          total_tokens: sum(l.total_tokens),
          prompt_tokens: sum(l.prompt_tokens),
          completion_tokens: sum(l.completion_tokens),
          cache_read_tokens: sum(l.cache_read_tokens),
          cache_write_tokens: sum(l.cache_write_tokens),
          avg_latency_ms: avg(l.latency_ms),
          total_cost_usd: sum(l.estimated_cost_usd),
          total_list_cost_usd: sum(l.list_cost_usd)
        }

    Repo.one(query) || empty_stats()
  end

  def stats_by_provider(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    # Count success + fallback as successful for the final provider (it handled the request)
    from(l in RequestLog,
      where:
        l.router_id == ^router.id and l.inserted_at >= ^since and
          l.traffic_type == "proxy" and not is_nil(l.final_provider),
      group_by: l.final_provider,
      select: %{
        provider: l.final_provider,
        total_requests: count(l.id),
        successful_requests:
          count(fragment("CASE WHEN ? IN ('success', 'fallback') THEN 1 END", l.status)),
        error_requests: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
        total_tokens: sum(l.total_tokens),
        avg_latency_ms: avg(l.latency_ms),
        total_cost_usd: sum(l.estimated_cost_usd),
        total_list_cost_usd: sum(l.list_cost_usd),
        cache_read_tokens: sum(l.cache_read_tokens)
      }
    )
    |> Repo.all()
  end

  @doc """
  Bucketed time series of request counts by status, spend, and tokens.

  Options: `:hours` (window, default 24) and `:bucket` (`:minute` | `:hour` | `:day`,
  default `:hour`). Buckets with no traffic are zero-filled so charts render a
  continuous axis. Ordered oldest → newest.
  """
  def timeseries(%Router{} = router, opts \\ []) do
    {since, bucket} = window(opts)

    rows =
      from(l in RequestLog,
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and l.traffic_type == "proxy",
        group_by: selected_as(:bucket),
        select: %{
          bucket:
            selected_as(fragment("date_trunc(?, ?)", ^to_string(bucket), l.inserted_at), :bucket),
          total: count(l.id),
          success: count(fragment("CASE WHEN ? = 'success' THEN 1 END", l.status)),
          fallback: count(fragment("CASE WHEN ? = 'fallback' THEN 1 END", l.status)),
          error: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
          cost_usd: sum(l.estimated_cost_usd),
          list_cost_usd: sum(l.list_cost_usd),
          total_tokens: sum(l.total_tokens)
        }
      )
      |> Repo.all()
      |> Map.new(&{normalize_bucket(&1.bucket), &1})

    empty = %{
      total: 0,
      success: 0,
      fallback: 0,
      error: 0,
      cost_usd: nil,
      list_cost_usd: nil,
      total_tokens: nil
    }

    for bucket_start <- bucket_range(since, bucket) do
      rows
      |> Map.get(bucket_start, empty)
      |> Map.put(:bucket, bucket_start)
    end
  end

  @doc """
  Bucketed spend broken down by final provider, pivoted for stacked charts.

  Returns `%{buckets: [DateTime], series: [%{provider, values, list_values}]}`
  with one value per bucket (zero-filled). `values` sums actual spend
  (`estimated_cost_usd`); `list_values` sums pay-as-you-go list prices
  (`list_cost_usd`) — the "would cost" of plan/subscription traffic. Series are
  sorted alphabetically so a provider keeps its position (and therefore its
  color) across refreshes.
  """
  def spend_timeseries(%Router{} = router, opts \\ []) do
    {since, bucket} = window(opts)

    rows =
      from(l in RequestLog,
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and
            l.traffic_type == "proxy" and not is_nil(l.final_provider) and
            (not is_nil(l.estimated_cost_usd) or not is_nil(l.list_cost_usd)),
        group_by: [selected_as(:bucket), l.final_provider],
        select: %{
          bucket:
            selected_as(fragment("date_trunc(?, ?)", ^to_string(bucket), l.inserted_at), :bucket),
          provider: l.final_provider,
          cost_usd: sum(l.estimated_cost_usd),
          list_cost_usd: sum(l.list_cost_usd)
        }
      )
      |> Repo.all()

    buckets = bucket_range(since, bucket)
    providers = rows |> Enum.map(& &1.provider) |> Enum.uniq() |> Enum.sort()

    by_key = Map.new(rows, fn row -> {{normalize_bucket(row.bucket), row.provider}, row} end)

    zero = Decimal.new(0)

    series =
      for provider <- providers do
        row_at = &Map.get(by_key, {&1, provider})

        %{
          provider: provider,
          values: Enum.map(buckets, fn b -> (row_at.(b) || %{})[:cost_usd] || zero end),
          list_values: Enum.map(buckets, fn b -> (row_at.(b) || %{})[:list_cost_usd] || zero end)
        }
      end

    %{buckets: buckets, series: series}
  end

  @doc """
  Bucketed latency percentiles (p50/p95). Buckets with no traffic are `nil`,
  not zero — a gap in the line, never a fake 0ms.
  """
  def latency_timeseries(%Router{} = router, opts \\ []) do
    {since, bucket} = window(opts)

    rows =
      from(l in RequestLog,
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and
            l.traffic_type == "proxy" and not is_nil(l.latency_ms),
        group_by: selected_as(:bucket),
        select: %{
          bucket:
            selected_as(fragment("date_trunc(?, ?)", ^to_string(bucket), l.inserted_at), :bucket),
          p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", l.latency_ms),
          p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", l.latency_ms)
        }
      )
      |> Repo.all()
      |> Map.new(&{normalize_bucket(&1.bucket), &1})

    for bucket_start <- bucket_range(since, bucket) do
      rows
      |> Map.get(bucket_start, %{p50: nil, p95: nil})
      |> Map.put(:bucket, bucket_start)
    end
  end

  @doc """
  Spend, requests, and tokens grouped by final model, highest spend first.
  """
  def spend_by_model(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    from(l in RequestLog,
      where:
        l.router_id == ^router.id and l.inserted_at >= ^since and
          l.traffic_type == "proxy" and not is_nil(l.final_model),
      group_by: [l.final_model, l.final_provider],
      order_by: [desc: sum(l.estimated_cost_usd)],
      select: %{
        model: l.final_model,
        provider: l.final_provider,
        total_requests: count(l.id),
        total_tokens: sum(l.total_tokens),
        cost_usd: sum(l.estimated_cost_usd),
        list_cost_usd: sum(l.list_cost_usd)
      }
    )
    |> Repo.all()
  end

  defp window(opts) do
    hours = Keyword.get(opts, :hours, 24)
    bucket = Keyword.get(opts, :bucket, :hour)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    {truncate_to_bucket(since, bucket), bucket}
  end

  # date_trunc comes back as NaiveDateTime for a naive timestamp column;
  # normalize both sides to UTC DateTime at second precision so map keys line
  # up (microsecond *precision* is part of struct equality).
  defp normalize_bucket(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp normalize_bucket(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp truncate_to_bucket(dt, :minute),
    do: DateTime.truncate(%{dt | second: 0, microsecond: {0, 0}}, :second)

  defp truncate_to_bucket(dt, :hour),
    do: DateTime.truncate(%{dt | minute: 0, second: 0, microsecond: {0, 0}}, :second)

  defp truncate_to_bucket(dt, :day),
    do: DateTime.truncate(%{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}, :second)

  defp bucket_seconds(:minute), do: 60
  defp bucket_seconds(:hour), do: 3600
  defp bucket_seconds(:day), do: 86_400

  defp bucket_range(since, bucket) do
    step = bucket_seconds(bucket)
    now = DateTime.utc_now()

    since
    |> Stream.iterate(&DateTime.add(&1, step, :second))
    |> Enum.take_while(&(DateTime.compare(&1, now) != :gt))
  end

  def stats_by_model(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    # Get all logs and aggregate from attempted_steps to capture all attempts
    logs =
      from(l in RequestLog,
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and
            l.traffic_type == "proxy",
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
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and
            l.traffic_type == "proxy" and not is_nil(l.latency_ms),
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
      where: l.router_id == ^router.id and l.inserted_at >= ^since and l.traffic_type == "proxy",
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
          l.traffic_type == "proxy" and
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

  # Sessions

  @doc """
  Lists distinct sessions across all routers for a user.
  """
  def list_sessions_for_user(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(l in RequestLog,
      join: r in Router,
      on: l.router_id == r.id,
      where: r.user_id == ^user.id and not is_nil(l.session_id),
      group_by: l.session_id,
      order_by: [desc: max(l.inserted_at)],
      limit: ^limit,
      offset: ^offset,
      select: %{
        session_id: l.session_id,
        session_name: max(l.session_name),
        request_count: count(l.id),
        last_activity: max(l.inserted_at),
        total_tokens: sum(l.total_tokens),
        avg_latency_ms: avg(l.latency_ms)
      }
    )
    |> Repo.all()
  end

  @doc """
  Lists distinct sessions for a router, ordered by most recent activity.

  Options: `:limit`, `:offset`, and `:hours` to restrict to sessions with
  activity inside a recent window (used by the dashboard).
  """
  def list_sessions(%Router{} = router, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(l in RequestLog,
      where: l.router_id == ^router.id and not is_nil(l.session_id),
      group_by: l.session_id,
      order_by: [desc: max(l.inserted_at)],
      limit: ^limit,
      offset: ^offset,
      select: %{
        session_id: l.session_id,
        session_name: max(l.session_name),
        request_count: count(l.id),
        last_activity: max(l.inserted_at),
        total_tokens: sum(l.total_tokens),
        avg_latency_ms: avg(l.latency_ms),
        total_cost_usd: sum(l.estimated_cost_usd),
        total_list_cost_usd: sum(l.list_cost_usd)
      }
    )
    |> maybe_filter_since_hours(opts[:hours])
    |> Repo.all()
  end

  defp maybe_filter_since_hours(query, nil), do: query

  defp maybe_filter_since_hours(query, hours) do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    where(query, [l], l.inserted_at >= ^since)
  end

  @doc """
  Lists all request logs belonging to a specific session.
  """
  def list_logs_by_session(%Router{} = router, session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(l in RequestLog,
      where: l.router_id == ^router.id and l.session_id == ^session_id,
      order_by: [asc: l.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Updates the session_name for all logs in a session.
  """
  def update_session_name(%Router{} = router, session_id, session_name) do
    from(l in RequestLog,
      where: l.router_id == ^router.id and l.session_id == ^session_id
    )
    |> Repo.update_all(set: [session_name: session_name])
  end

  @doc """
  Gets aggregate stats for a session.
  """
  def session_stats(%Router{} = router, session_id) do
    from(l in RequestLog,
      where: l.router_id == ^router.id and l.session_id == ^session_id,
      select: %{
        request_count: count(l.id),
        total_tokens: sum(l.total_tokens),
        prompt_tokens: sum(l.prompt_tokens),
        completion_tokens: sum(l.completion_tokens),
        avg_latency_ms: avg(l.latency_ms),
        total_cost_usd: sum(l.estimated_cost_usd),
        total_list_cost_usd: sum(l.list_cost_usd),
        successful_requests:
          count(fragment("CASE WHEN ? IN ('success', 'fallback') THEN 1 END", l.status)),
        error_requests: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
        first_request: min(l.inserted_at),
        last_request: max(l.inserted_at)
      }
    )
    |> Repo.one()
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

  defp maybe_filter_favorite(query, true), do: where(query, [l], l.favorite == true)
  defp maybe_filter_favorite(query, _), do: query

  defp empty_stats do
    %{
      total_requests: 0,
      successful_requests: 0,
      fallback_requests: 0,
      error_requests: 0,
      total_tokens: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      avg_latency_ms: nil,
      total_cost_usd: nil,
      total_list_cost_usd: nil
    }
  end

  @doc """
  Returns cache-specific stats: total cached tokens, hit rate, estimated savings.
  """
  def cache_stats(%Router{} = router, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    result =
      from(l in RequestLog,
        where:
          l.router_id == ^router.id and l.inserted_at >= ^since and
            not is_nil(l.prompt_tokens),
        select: %{
          total_prompt_tokens: sum(l.prompt_tokens),
          cache_read_tokens: sum(l.cache_read_tokens),
          cache_write_tokens: sum(l.cache_write_tokens),
          cached_requests: count(fragment("CASE WHEN ? > 0 THEN 1 END", l.cache_read_tokens)),
          total_requests: count(l.id)
        }
      )
      |> Repo.one()

    case result do
      nil ->
        %{
          hit_rate: 0.0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          cached_requests: 0,
          total_requests: 0
        }

      stats ->
        prompt_tokens = stats.total_prompt_tokens || 0
        cache_read = stats.cache_read_tokens || 0
        cache_write = stats.cache_write_tokens || 0

        hit_rate = Usage.cache_hit_pct(prompt_tokens, cache_read, cache_write) || 0.0

        %{
          hit_rate: hit_rate,
          cache_read_tokens: cache_read,
          cache_write_tokens: cache_write,
          cached_requests: stats.cached_requests || 0,
          total_requests: stats.total_requests || 0
        }
    end
  end
end
