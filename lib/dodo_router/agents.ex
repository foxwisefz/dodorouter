defmodule DodoRouter.Agents do
  @moduledoc """
  Credentials and audit for the agent surface.

  Two responsibilities that belong together: minting the scoped tokens an
  agent authenticates with, and recording what was done with them. Neither is
  worth much alone — a scoped credential nobody can review is still a credential
  you cannot reason about after a leak.
  """

  import Ecto.Query

  alias DodoRouter.Accounts
  alias DodoRouter.Accounts.User
  alias DodoRouter.Agents.{AgentToken, ApiCall, Principal}
  alias DodoRouter.Repo
  alias DodoRouter.Routers

  require Logger

  # last_used_at is a liveness hint, not an audit record — agent_api_calls is
  # the audit record. Writing it on every request would add a write to every
  # read for a field nobody reads to the second.
  @touch_after_seconds 60

  ## Tokens

  def list_tokens(%User{} = user) do
    from(t in AgentToken,
      where: t.user_id == ^user.id,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  The routers a token reaches, resolved for display.

  `all_routers` is answered live rather than from a stored list — that is the
  whole point of the flag, and a UI that showed a snapshot would under-report
  what the credential can actually reach today.
  """
  # Takes a principal, not a credential. Written against `%AgentToken{}` first,
  # which broke the moment an OAuth principal arrived carrying `token: nil` —
  # reach is a property of who is calling, not of how they authenticated, and
  # matching on the credential is exactly the leak `Principal` exists to stop.
  def routers_for(%User{} = user, %Principal{all_routers: true}), do: Routers.list_routers(user)

  def routers_for(%User{} = user, %Principal{router_ids: ids}) do
    user |> Routers.list_routers() |> Enum.filter(&(&1.id in ids))
  end

  def routers_for(%User{} = user, %AgentToken{} = token),
    do: routers_for(user, Principal.from_token(token, user))

  def get_token(%User{} = user, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(AgentToken, id: uuid, user_id: user.id)
      :error -> nil
    end
  end

  @doc """
  Mints a token. The returned struct carries the secret in `:token` — this is
  the only time it exists anywhere, so the caller must show it now or lose it.
  """
  def create_token(%User{} = user, attrs) do
    attrs
    |> AgentToken.create_changeset(user.id)
    |> validate_router_ownership(user)
    |> Repo.insert()
  end

  # The ids arrive as client params. `Principal.allows_router?/2` re-checks
  # ownership on every request, so an unowned id could never actually be used —
  # but storing one would show a router in the token's own summary that its
  # holder cannot reach, and a credential that misreports its reach is worse
  # than one that is refused at mint time.
  defp validate_router_ownership(%Ecto.Changeset{valid?: false} = changeset, _user),
    do: changeset

  defp validate_router_ownership(changeset, user) do
    ids = Ecto.Changeset.get_field(changeset, :router_ids) || []
    owned = user |> Routers.list_routers() |> MapSet.new(& &1.id)

    case Enum.reject(ids, &MapSet.member?(owned, &1)) do
      [] ->
        changeset

      unowned ->
        Ecto.Changeset.add_error(
          changeset,
          :router_ids,
          "not your routers: #{Enum.join(unowned, ", ")}"
        )
    end
  end

  def change_token(attrs \\ %{}, user_id \\ nil),
    do: AgentToken.create_changeset(attrs, user_id)

  @doc """
  Revokes rather than deletes.

  A deleted token takes its name out of every audit row that referenced it
  (the FK nilifies), and the history of a credential is most interesting
  immediately after someone decides to revoke it.
  """
  def revoke_token(%User{} = user, id) do
    case get_token(user, id) do
      nil ->
        {:error, :not_found}

      %AgentToken{revoked_at: %DateTime{}} = token ->
        {:ok, token}

      token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
    end
  end

  @doc """
  Resolves a raw bearer token into a principal.

  Returns the specific reason on failure so the caller can say "expired"
  rather than a flat "invalid" — but note the caller is responsible for
  deciding how much of that reaches the wire.
  """
  def authenticate(raw_token) when is_binary(raw_token) do
    hash = AgentToken.hash_token(raw_token)

    case Repo.get_by(AgentToken, token_hash: hash) do
      nil ->
        {:error, :invalid}

      token ->
        with {:ok, token} <- AgentToken.usable(token) do
          touch(token)
          {:ok, Principal.from_token(token, Accounts.get_user!(token.user_id))}
        end
    end
  end

  def authenticate(_raw_token), do: {:error, :invalid}

  defp touch(%AgentToken{} = token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if stale?(token.last_used_at, now) do
      from(t in AgentToken, where: t.id == ^token.id)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  defp stale?(nil, _now), do: true

  defp stale?(last_used_at, now),
    do: DateTime.diff(now, last_used_at, :second) >= @touch_after_seconds

  ## Audit

  @doc """
  Records one call against the agent surface.

  Never raises: an audit write that can take down the API it audits would get
  removed the first time it did, and then there would be no audit at all. A
  failure is logged loudly instead — that line is the signal that the record
  is incomplete.
  """
  def record_call(attrs) do
    %ApiCall{}
    |> ApiCall.changeset(attrs)
    |> Repo.insert()
  rescue
    exception ->
      Logger.error("""
      agent audit write failed — this call is NOT recorded: #{Exception.message(exception)}
      attrs: #{inspect(Map.drop(attrs, [:error]))}
      """)

      {:error, :audit_write_failed}
  end

  def list_calls(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(c in ApiCall,
      where: c.user_id == ^user.id,
      order_by: [desc: c.inserted_at],
      limit: ^limit,
      preload: [:agent_token, :router]
    )
    |> filter_outcome(opts[:outcome])
    |> filter_token(opts[:agent_token_id])
    |> Repo.all()
  end

  defp filter_outcome(query, nil), do: query
  defp filter_outcome(query, outcome), do: where(query, [c], c.outcome == ^outcome)

  defp filter_token(query, nil), do: query
  defp filter_token(query, id), do: where(query, [c], c.agent_token_id == ^id)

  @doc """
  Counts per outcome for a token, so the UI can show that a credential is
  being refused without making the operator read individual rows.
  """
  def call_stats(%User{} = user, opts \\ []) do
    from(c in ApiCall,
      where: c.user_id == ^user.id,
      group_by: c.outcome,
      select: {c.outcome, count()}
    )
    |> filter_token(opts[:agent_token_id])
    |> Repo.all()
    |> Map.new()
  end
end
