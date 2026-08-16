defmodule DodoRouter.Providers do
  @moduledoc """
  Context for managing provider API keys.
  """

  import Ecto.Query
  alias DodoRouter.Providers.KeyHealth
  alias DodoRouter.Repo
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Accounts.User
  alias DodoRouter.Routers.Router
  alias DodoRouter.Routers.RoutingStep

  @doc """
  Lists all provider keys for a user.
  """
  def list_provider_keys(%User{id: user_id}) do
    ProviderKey
    |> where(user_id: ^user_id)
    |> order_by([pk], [pk.provider_slug, pk.label])
    |> Repo.all()
  end

  @doc """
  Lists provider keys for a user, grouped by provider_slug.
  """
  def list_provider_keys_grouped(%User{} = user) do
    user
    |> list_provider_keys()
    |> Enum.group_by(& &1.provider_slug)
  end

  @doc """
  Gets a single provider key for a user.
  """
  def get_provider_key(%User{id: user_id}, id) do
    ProviderKey
    |> where(user_id: ^user_id, id: ^id)
    |> Repo.one()
  end

  @doc """
  Gets a provider key by ID. Raises if not found.
  """
  def get_provider_key!(%User{id: user_id}, id) do
    ProviderKey
    |> where(user_id: ^user_id, id: ^id)
    |> Repo.one!()
  end

  @doc """
  Creates a provider key and stores the API key in Infisical.
  """
  def create_provider_key(%User{id: user_id} = _user, attrs, api_key_value) do
    hint = generate_key_hint(api_key_value)
    do_create_provider_key(user_id, attrs, api_key_value, hint)
  end

  def create_provider_key_with_hint(%User{id: user_id}, attrs, api_key_value, hint) do
    do_create_provider_key(user_id, attrs, api_key_value, hint)
  end

  defp do_create_provider_key(user_id, attrs, api_key_value, hint) do
    changeset = ProviderKey.create_changeset(%ProviderKey{}, attrs, user_id, hint)

    case Repo.insert(changeset) do
      {:ok, provider_key} ->
        # Store the actual API key in Infisical
        case store_api_key(user_id, provider_key.key_ref, api_key_value) do
          :ok ->
            {:ok, provider_key}

          {:error, reason} ->
            # Rollback the database insert
            Repo.delete(provider_key)
            {:error, {:secret_storage_failed, reason}}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Replaces the raw secret for an existing provider key.
  """
  def update_provider_key_secret(%ProviderKey{user_id: user_id, key_ref: key_ref}, value) do
    store_api_key(user_id, key_ref, value)
  end

  @doc """
  Updates a provider key's metadata (label).
  Does not update the API key itself.
  """
  def update_provider_key(%ProviderKey{} = provider_key, attrs) do
    provider_key
    |> ProviderKey.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a provider key and its stored secret.

  Returns `{:error, :in_use}` when an evaluation still references the key,
  as its judge or as one of its candidates. Both keep an evaluation
  re-runnable, so neither may be silently orphaned. Pass
  `reassign_to: %ProviderKey{}` to move every reference to another key of
  the same provider first; the move and the delete share a transaction, so
  a refused delete never leaves an evaluation pointing at a key the user
  did not choose.

  Only the judge reference is enforced by the database
  (`evaluations_judge_provider_key_id_fkey`, `ON DELETE RESTRICT`).
  Candidates live in a JSON column with no foreign key, so they are checked
  here — a delete Postgres is happy to accept still breaks the next re-run.

  The row goes first and the secret second. The other order destroys the
  credential behind a key that is still there when the delete is refused —
  the key stays listed, looks fine, and can never authenticate again.
  """
  def delete_provider_key(%ProviderKey{} = provider_key, opts \\ []) do
    result =
      Repo.transaction(fn ->
        with :ok <- reassign_references(provider_key, opts[:reassign_to]),
             :ok <- check_unreferenced(provider_key),
             {:ok, deleted} <- Repo.delete(delete_changeset(provider_key)) do
          deleted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, deleted} ->
        delete_api_key(provider_key.user_id, provider_key.key_ref)
        {:ok, deleted}

      {:error, %Ecto.Changeset{}} ->
        {:error, :in_use}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reassign_references(_provider_key, nil), do: :ok

  defp reassign_references(%ProviderKey{} = provider_key, %ProviderKey{} = replacement) do
    # Cross-context on purpose: the references being moved belong to
    # Evaluations, and only that context knows what a judge or a candidate
    # target is.
    DodoRouter.Evaluations.reassign_provider_key(provider_key, replacement)
  end

  # Runs after any reassignment, so it sees what is actually left.
  defp check_unreferenced(%ProviderKey{} = provider_key) do
    case DodoRouter.Evaluations.reference_counts(provider_key) do
      %{judge: 0, candidate: 0} -> :ok
      _ -> {:error, :in_use}
    end
  end

  defp delete_changeset(%ProviderKey{} = provider_key) do
    provider_key
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :evaluations_judge_provider_key_id_fkey,
      message: "is the judge for existing evaluations"
    )
  end

  @doc """
  The blast radius of deleting a provider key, for every key in `key_ids` at
  once — a destructive confirmation needs this stated, not left to a hover
  tooltip, and a page listing many keys must not run one query per key.

  Returns `%{key_id => %{routing_step_count:, router_names:, request_count_24h:}}`.
  `routing_step_count`/`router_names` come from the exact `provider_key_id`
  foreign key on `routing_steps`. `request_count_24h` is an exact count of
  distinct requests whose `attempted_steps` snapshot named this key — the
  denormalized record of which key an attempt actually used, not an
  approximation via the key's current routing steps (a request may have
  used a key a routing step no longer references).
  """
  def usage_summary_for_keys(key_ids, opts \\ [])
  def usage_summary_for_keys([], _opts), do: %{}

  def usage_summary_for_keys(key_ids, opts) do
    hours = Keyword.get(opts, :hours, 24)
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    step_rows =
      from(rs in RoutingStep,
        join: r in Router,
        on: rs.router_id == r.id,
        where: rs.provider_key_id in ^key_ids,
        group_by: rs.provider_key_id,
        select: {rs.provider_key_id, count(rs.id), fragment("array_agg(DISTINCT ?)", r.name)}
      )
      |> Repo.all()
      |> Map.new(fn {key_id, count, names} -> {key_id, {count, names}} end)

    request_counts = request_counts_since(key_ids, since)

    Map.new(key_ids, fn key_id ->
      {step_count, router_names} = Map.get(step_rows, key_id, {0, []})

      {key_id,
       %{
         routing_step_count: step_count,
         router_names: router_names,
         request_count_24h: Map.get(request_counts, key_id, 0)
       }}
    end)
  end

  # `attempted_steps` is jsonb, not a foreign key, so this is a raw query
  # over `jsonb_array_elements` rather than Ecto's query DSL. Grouped once
  # for every key in `key_ids`, not one query per key.
  defp request_counts_since(key_ids, since) do
    ids = Enum.map(key_ids, &to_string/1)

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT step->>'provider_key_id' AS provider_key_id, count(DISTINCT l.id)
        FROM request_logs l, jsonb_array_elements(l.attempted_steps) AS step
        WHERE l.inserted_at >= $1
          AND step->>'provider_key_id' = ANY($2)
        GROUP BY step->>'provider_key_id'
        """,
        [since, ids]
      )

    Map.new(rows, fn [key_id, count] -> {Ecto.UUID.cast!(key_id), count} end)
  end

  @doc """
  Keys of the same provider the user could move a judge reference to.

  Same provider only: an evaluation records `judge_model` alongside the key,
  so pointing it at another provider's credential would claim a model judged
  it that never ran there.
  """
  def reassignment_candidates(%ProviderKey{} = provider_key) do
    ProviderKey
    |> where(user_id: ^provider_key.user_id, provider_slug: ^provider_key.provider_slug)
    |> where([pk], pk.id != ^provider_key.id)
    |> order_by([pk], pk.label)
    |> Repo.all()
  end

  @doc """
  Gets the raw API key value from Infisical for a provider key.
  """
  def get_raw_api_key(%ProviderKey{user_id: user_id, key_ref: key_ref}) do
    DodoRouter.Secrets.get_provider_key(user_id, key_ref)
  end

  def get_raw_api_key(nil), do: nil

  @doc """
  Resolves the usable API key for a provider key.

  For OAuth-based providers (e.g. OpenAI Codex), this decodes the stored
  credentials, refreshes the access token if needed, and returns the full
  encoded JSON credentials (so the adapter can extract the access token
  and account_id). For regular providers, returns the raw key as-is.
  """
  def resolve_api_key(%ProviderKey{provider_slug: "openai-codex"} = provider_key) do
    raw = get_raw_api_key(provider_key)

    case DodoRouter.OpenAICodexOAuth.ensure_access_token(provider_key, raw) do
      {:ok, _token, _account_id} ->
        # ensure_access_token refreshed and persisted; re-read the updated creds
        get_raw_api_key(provider_key)

      _ ->
        nil
    end
  end

  def resolve_api_key(%ProviderKey{} = provider_key) do
    get_raw_api_key(provider_key)
  end

  def resolve_api_key(nil), do: nil

  # Internal functions for Infisical storage

  defp store_api_key(user_id, key_ref, value) do
    DodoRouter.Secrets.put_provider_key(user_id, key_ref, value)
  end

  defp delete_api_key(user_id, key_ref) do
    DodoRouter.Secrets.delete_provider_key(user_id, key_ref)
  end

  @doc """
  Records key health from a completed proxy dispatch's attempted steps.

  Takes the terminal outcome per provider key (a request may retry the same
  key), classifies it, and applies the KeyHealth state machine with a
  targeted update_all — no read-modify-write, safe under concurrency.
  Steps without an assigned key (shared/legacy keys) are skipped.
  """
  def record_attempts(attempted_steps) when is_list(attempted_steps) do
    attempted_steps
    |> Enum.filter(& &1[:provider_key_id])
    |> Enum.group_by(& &1[:provider_key_id])
    |> Enum.each(fn {key_id, attempts} ->
      attempt = List.last(attempts)

      class =
        if attempt[:status] == "success" do
          :ok
        else
          KeyHealth.classify(
            attempt[:http_status],
            error_reason_atom(attempt[:error]),
            attempt[:error_body]
          )
        end

      apply_health(key_id, class, KeyHealth.error_detail(attempt[:error_body]))
    end)
  end

  def record_attempts(_), do: :ok

  @doc """
  Applies a health class to a key. Reads only the current status, then
  writes the transition via update_all keyed on that status so concurrent
  writers converge instead of clobbering.
  """
  def apply_health(key_id, class, detail \\ nil) do
    case Repo.one(from k in ProviderKey, where: k.id == ^key_id, select: {k.id, k.status}) do
      nil ->
        :ok

      {_id, current} ->
        {new_status, fields} = KeyHealth.transition(current, class)

        fields =
          fields
          |> Map.merge(if detail && class != :ok, do: %{last_error_detail: detail}, else: %{})
          |> Map.merge(if new_status == :unchanged, do: %{}, else: %{status: new_status})

        {_count, _} =
          Repo.update_all(
            from(k in ProviderKey, where: k.id == ^key_id),
            set: Map.to_list(fields)
          )

        :ok
    end
  end

  @doc "Marks a key as actively verified just now."
  def mark_key_verified(key_id) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(k in ProviderKey, where: k.id == ^key_id),
      set: [
        status: "valid",
        verified_at: now,
        last_error_class: nil,
        last_error_at: nil,
        last_error_detail: nil
      ]
    )

    :ok
  end

  defp error_reason_atom(nil), do: nil
  defp error_reason_atom("timeout"), do: :timeout
  defp error_reason_atom("network_error"), do: :network_error
  defp error_reason_atom(_), do: nil

  # show bits of API key
  @doc false
  def generate_key_hint(nil), do: ""

  @doc false
  def generate_key_hint(key) do
    len = String.length(key)

    hint =
      cond do
        len <= 4 ->
          String.duplicate("•", len)

        len < 9 ->
          prefix = String.slice(key, 0, 2)
          bullets = String.duplicate("•", len - 2)
          prefix <> bullets

        len < 12 ->
          prefix = String.slice(key, 0, 3)
          bullets = String.duplicate("•", len - 3)
          prefix <> bullets

        true ->
          # Fixed-width mask: length-preserving bullets made long keys
          # overflow every UI element that renders a hint.
          prefix = String.slice(key, 0, 3)
          suffix = String.slice(key, -3..-1//1)
          "#{prefix}••••#{suffix}"
      end

    hint
  end

  @doc """
  Collapses bullet runs in key hints stored under the old length-preserving
  scheme, so existing rows display at the same fixed width as new ones.
  """
  def compact_key_hint(nil), do: ""
  def compact_key_hint(hint), do: String.replace(hint, ~r/•{5,}/u, "••••")

  # Keys that bill against a subscription or coding plan rather than metered
  # API credit. Enumerated explicitly rather than inferred, because the obvious
  # heuristics are both wrong: "slug contains coding" misses `anthropic_oauth`
  # and `openai-codex`, while "key slug differs from the adapter slug" wrongly
  # flags `zai_standard`, which is metered. A short honest list beats a rule
  # that quietly misclassifies.
  #
  # `Replays.plan_type_for/1` delegates to `subscription_key?/1` (rather than
  # keeping its own "coding" substring check) — see dodo_router-uuh.
  @subscription_key_slugs ~w(
    anthropic_oauth
    openai-codex
    moonshot_coding
    zai_coding
    test_provider_coding
  )

  @doc """
  Whether this key draws on a subscription/plan rather than metered API credit.

  Matters beyond cost reporting: plan credentials are provisioned for a
  vendor's own coding environment and can refuse or throttle traffic that did
  not originate there. For a judge — which has to answer for a benchmark to
  produce a score at all — that is a failed run, not a cheaper one.
  """
  def subscription_key?(%ProviderKey{provider_slug: slug}), do: slug in @subscription_key_slugs
  def subscription_key?(%{provider_slug: slug}), do: slug in @subscription_key_slugs
  def subscription_key?(slug) when is_binary(slug), do: slug in @subscription_key_slugs
  def subscription_key?(_key), do: false

  @doc "Billing model of a key, for display: `:subscription` or `:metered`."
  def billing(key), do: if(subscription_key?(key), do: :subscription, else: :metered)

  @doc "The subscription key slugs, for UI copy and tests."
  def subscription_key_slugs, do: @subscription_key_slugs
end
