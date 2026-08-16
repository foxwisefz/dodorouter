defmodule DodoRouter.Recordings do
  @moduledoc """
  The Recordings context - manages server-side request capture sessions.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Recordings.Recording
  alias DodoRouter.Routers.Router

  def start_recording(%Router{} = router, attrs \\ %{}) do
    attrs = Map.put(attrs, :router_id, router.id)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:stop_existing, fn _repo, _changes ->
      stop_active_query(router)
      {:ok, nil}
    end)
    |> Ecto.Multi.insert(:recording, Recording.start_changeset(%Recording{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{recording: recording}} -> {:ok, recording}
      {:error, _op, changeset, _changes} -> {:error, changeset}
    end
  end

  def stop_recording(%Router{} = router) do
    case get_active_recording(router) do
      nil -> {:error, :not_found}
      recording -> stop_recording(recording)
    end
  end

  def stop_recording(%Recording{} = recording) do
    recording
    |> Recording.stop_changeset()
    |> Repo.update()
  end

  def get_active_recording(%Router{} = router) do
    from(r in Recording,
      where: r.router_id == ^router.id and r.status == "recording",
      limit: 1
    )
    |> Repo.one()
  end

  def get_recording!(id) do
    Repo.get!(Recording, id)
  end

  # Ownership-scoped fetch, for the entry points where a recording id
  # triggers spending (benchmark creation): the id arrives as a client
  # param, so it is resolved through the router's owner rather than
  # trusted. Returns nil for someone else's recording, same as a missing
  # one — existence is not leaked either way.
  def get_recording(%DodoRouter.Accounts.User{} = user, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        from(r in Recording,
          join: router in Router,
          on: r.router_id == router.id,
          where: r.id == ^uuid and router.user_id == ^user.id
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  def list_recordings(%Router{} = router, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(r in Recording,
      where: r.router_id == ^router.id,
      order_by: [desc: r.started_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  def list_recordings_for_user(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(r in Recording,
      join: router in Router,
      on: r.router_id == router.id,
      where: router.user_id == ^user.id,
      order_by: [desc: r.started_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:router]
    )
    |> Repo.all()
  end

  def recording_stats(%Recording{} = recording) do
    alias DodoRouter.Logs.RequestLog

    from(l in RequestLog,
      where: l.recording_id == ^recording.id,
      select: %{
        request_count: count(l.id),
        total_tokens: sum(l.total_tokens),
        prompt_tokens: sum(l.prompt_tokens),
        completion_tokens: sum(l.completion_tokens),
        avg_latency_ms: avg(l.latency_ms),
        successful_requests:
          count(fragment("CASE WHEN ? IN ('success', 'fallback') THEN 1 END", l.status)),
        error_requests: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status)),
        # What this capture's traffic cost at API list prices — the
        # comparable figure when plan keys metered $0. Coalesced per row:
        # logs recorded before list prices were captured fall back to
        # their actual cost.
        total_list_cost_usd: sum(coalesce(l.list_cost_usd, l.estimated_cost_usd)),
        # And what was actually metered, uncoalesced — readers get both
        # figures separately rather than one blended number.
        total_cost_usd: sum(l.estimated_cost_usd)
      }
    )
    |> Repo.one()
  end

  def list_logs_for_recording(%Recording{} = recording, opts \\ []) do
    alias DodoRouter.Logs.RequestLog

    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(l in RequestLog,
        where: l.recording_id == ^recording.id,
        order_by: [asc: l.inserted_at]
      )

    # :all exists for the benchmark sampler, which must see the whole
    # capture to spread its picks across it — a page would silently bias
    # the sample toward session start. Recordings are bounded sessions,
    # so "all" is dozens to a few hundred rows, not a table scan.
    query =
      case limit do
        :all -> query
        limit -> from(l in query, limit: ^limit, offset: ^offset)
      end

    Repo.all(query)
  end

  @doc """
  Captured-request counts for a set of recordings, in one query.
  """
  def log_counts(recording_ids) when is_list(recording_ids) do
    alias DodoRouter.Logs.RequestLog

    from(l in RequestLog,
      where: l.recording_id in ^recording_ids,
      group_by: l.recording_id,
      select: {l.recording_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp stop_active_query(%Router{} = router) do
    from(r in Recording,
      where: r.router_id == ^router.id and r.status == "recording"
    )
    |> Repo.update_all(set: [status: "stopped", stopped_at: DateTime.utc_now()])
  end
end
