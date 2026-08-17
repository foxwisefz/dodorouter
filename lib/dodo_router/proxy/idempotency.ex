defmodule DodoRouter.Proxy.Idempotency do
  @moduledoc """
  Stripe-style Idempotency-Key semantics for the proxy endpoints.

  A client that retries a request it is not sure completed — the batch
  backfill whose upstream call succeeded but whose own DB write failed —
  sends the same `Idempotency-Key` and gets the stored answer back instead
  of paying for a second generation. The proxy is the only component that
  sees every call, so it is the right place for the guarantee.

  The semantics follow the industry consensus (Stripe, PayPal, OpenAI's
  commerce APIs, and the IETF `Idempotency-Key` draft):

  * a reused key with a **different request body is rejected**, never
    served-anyway — a silent wrong answer is worse than a loud 409;
  * a retry that arrives while the **original is still executing** is
    rejected with a retry-later, not run a second time;
  * keys expire after #{div(86_400, 3600)}h, after which the same key
    executes fresh;
  * only **successful, fully-stored** responses replay — an error, or a
    response the log truncated for storage, executes fresh rather than
    re-serving something broken.

  Replay happens at the IR level: the stored `response_body` is the
  OpenAI-shaped intermediate representation, and each endpoint's own
  egress conversion renders it — so a key retried against `/v1/messages`
  gets a correctly Anthropic-shaped body even though one stored value
  backs both formats.
  """

  import Ecto.Query

  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Proxy.IdempotencyKey
  alias DodoRouter.Repo

  @ttl_seconds 24 * 3600
  # An in-progress reservation older than this belongs to a dispatch that
  # died without abandoning (provider calls cap at ~2 minutes, so 15 is
  # generous). Taking it over beats wedging the key for a day.
  @in_progress_grace_seconds 15 * 60
  @max_attempts 3

  @doc """
  Claims `key` for this dispatch, or resolves what already claimed it.

  Returns:

  * `{:proceed, :reserved}` — the key is ours; the caller must
    `commit/3` on success or `abandon/3` on failure.
  * `{:replay, response, original_log}` — a completed, replayable
    response exists; serve it instead of calling upstream.
  * `{:error, :mismatch}` — the key was used with a different body.
  * `{:error, :in_progress}` — the original request is still executing.
  """
  def begin(router_id, key, request, request_id) do
    attempt(router_id, key, request_hash(request), request_id, @max_attempts)
  end

  # Bounded retries: every loop iteration first deletes the row that blocked
  # it, so a second conflict means another writer raced us — after a few
  # rounds, surface the state we keep finding rather than spinning.
  defp attempt(_router_id, _key, _hash, _request_id, 0), do: {:error, :in_progress}

  defp attempt(router_id, key, hash, request_id, attempts_left) do
    case insert_reservation(router_id, key, hash, request_id) do
      :inserted ->
        {:proceed, :reserved}

      :conflict ->
        case Repo.get_by(IdempotencyKey, router_id: router_id, key: key) do
          nil ->
            # The blocking row was deleted between our insert and read.
            attempt(router_id, key, hash, request_id, attempts_left - 1)

          row ->
            resolve(row, router_id, key, hash, request_id, attempts_left)
        end
    end
  end

  defp resolve(row, router_id, key, hash, request_id, attempts_left) do
    retry = fn ->
      delete_row(row)
      attempt(router_id, key, hash, request_id, attempts_left - 1)
    end

    cond do
      expired?(row) ->
        retry.()

      # Checked before in_progress, like Stripe: a different body under the
      # same key is client misuse whatever state the original is in.
      row.request_hash != hash ->
        {:error, :mismatch}

      row.status == "in_progress" and stuck?(row) ->
        retry.()

      row.status == "in_progress" ->
        {:error, :in_progress}

      true ->
        case replayable_response(row) do
          {:ok, response, log} ->
            {:replay, response, log}

          # Completed but nothing honest to serve (log gone, error row, or
          # a response the log truncated): execute fresh and let this
          # dispatch's result take the key over.
          :not_replayable ->
            retry.()
        end
    end
  end

  @doc "Marks this dispatch's reservation replayable."
  def commit(router_id, key, request_id) do
    from(k in IdempotencyKey,
      where:
        k.router_id == ^router_id and k.key == ^key and k.request_id == ^request_id and
          k.status == "in_progress"
    )
    |> Repo.update_all(set: [status: "completed", updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Releases this dispatch's reservation so a retry executes fresh — a stored
  502 replayed at zero cost would be a hostile kind of savings.
  """
  def abandon(router_id, key, request_id) do
    from(k in IdempotencyKey,
      where: k.router_id == ^router_id and k.key == ^key and k.request_id == ^request_id
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  A deterministic fingerprint of the dispatched request, for the
  reused-with-different-body check. Hashes the IR (post ingress
  conversion), so the comparison is format-agnostic.
  """
  def request_hash(request) do
    :crypto.hash(:sha256, :erlang.term_to_binary(request, [:deterministic]))
  end

  defp insert_reservation(router_id, key, hash, request_id) do
    row = %{
      id: Ecto.UUID.generate(),
      router_id: router_id,
      key: key,
      request_hash: hash,
      request_id: request_id,
      status: "in_progress",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case Repo.insert_all(IdempotencyKey, [row], on_conflict: :nothing) do
      {1, _} -> :inserted
      {0, _} -> :conflict
    end
  end

  # Guarded by id so a row another dispatch already replaced is not deleted
  # out from under it.
  defp delete_row(row) do
    from(k in IdempotencyKey, where: k.id == ^row.id) |> Repo.delete_all()
  end

  defp expired?(row) do
    DateTime.diff(DateTime.utc_now(), row.inserted_at, :second) >= @ttl_seconds
  end

  defp stuck?(row) do
    DateTime.diff(DateTime.utc_now(), row.updated_at, :second) >= @in_progress_grace_seconds
  end

  # The stored response is only served when it is the whole truth: a
  # successful request whose body survived storage untruncated. The
  # `_truncation_flags` marker the log writer embeds is the tell — a
  # truncated answer replayed as complete would be corruption sold as
  # savings.
  defp replayable_response(row) do
    log =
      Repo.one(
        from(l in RequestLog,
          where: l.router_id == ^row.router_id and l.request_id == ^row.request_id,
          limit: 1
        )
      )

    with %RequestLog{status: status, response_body: body} = log
         when status in ["success", "fallback"] and is_binary(body) <- log,
         {:ok, %{} = response} <- Jason.decode(body),
         false <- Map.has_key?(response, "_truncation_flags") do
      {:ok, ensure_model(response, log), log}
    else
      _ -> :not_replayable
    end
  end

  # Bodies logged before model-stamping existed carry no model; the log row
  # always knew what served it, so a replay must say so too rather than
  # re-serving the old blank (dodo_router-bnn).
  defp ensure_model(response, log) do
    case response["model"] do
      model when is_binary(model) and model != "" ->
        response

      _blank ->
        if is_binary(log.final_model) and log.final_model != "",
          do: Map.put(response, "model", log.final_model),
          else: response
    end
  end
end
