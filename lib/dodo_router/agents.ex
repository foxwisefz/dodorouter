defmodule DodoRouter.Agents do
  @moduledoc """
  What an agent may reach, and a record of what it did.

  Authentication itself is not here: agents authenticate with an OAuth access
  token minted by `DodoRouter.AuthZ`, so this module only answers the two
  questions that outlive the credential — which routers a caller reaches, and
  what happened on every call. A scoped credential nobody can review is still
  a credential you cannot reason about after a leak.
  """

  import Ecto.Query

  alias DodoRouter.Accounts.User
  alias DodoRouter.Agents.{ApiCall, Principal}
  alias DodoRouter.Repo
  alias DodoRouter.Routers

  require Logger

  ## Reach

  @doc """
  The routers a principal reaches, resolved live.

  `all_routers` is answered against the account as it is now rather than from
  a stored list — a UI or a tool that showed a snapshot would under-report what
  the credential can actually reach today.
  """
  # Takes a principal, not a credential. It was written against the bearer-token
  # struct first and broke the moment an OAuth principal arrived carrying no
  # such token — reach is a property of who is calling, not of how they
  # authenticated, and matching on the credential is exactly the leak
  # `Principal` exists to stop.
  def routers_for(%User{} = user, %Principal{all_routers: true}), do: Routers.list_routers(user)

  def routers_for(%User{} = user, %Principal{router_ids: ids}) do
    user |> Routers.list_routers() |> Enum.filter(&(&1.id in ids))
  end

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
      preload: [:router]
    )
    |> filter_outcome(opts[:outcome])
    |> filter_client(opts[:client])
    |> Repo.all()
  end

  defp filter_outcome(query, nil), do: query
  defp filter_outcome(query, outcome), do: where(query, [c], c.outcome == ^outcome)

  defp filter_client(query, nil), do: query
  defp filter_client(query, name), do: where(query, [c], c.principal_name == ^name)

  @doc """
  Counts per outcome, so the UI can show that a caller is being refused
  without making the operator read individual rows.
  """
  def call_stats(%User{} = user, opts \\ []) do
    from(c in ApiCall,
      where: c.user_id == ^user.id,
      group_by: c.outcome,
      select: {c.outcome, count()}
    )
    |> filter_client(opts[:client])
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  One row per OAuth client that has called, newest activity first.

  The client is the closest thing to a credential identity now that tokens are
  short-lived and minted per session: an operator asking "what is connected to
  my account" means clients, not individual access tokens.
  """
  def list_clients(%User{} = user) do
    from(c in ApiCall,
      where: c.user_id == ^user.id and not is_nil(c.principal_name),
      group_by: c.principal_name,
      select: %{
        name: c.principal_name,
        calls: count(),
        last_seen_at: max(c.inserted_at),
        denied: filter(count(), c.outcome == "denied"),
        read_bodies: filter(count(), c.returned_bodies == true)
      },
      order_by: [desc: max(c.inserted_at)]
    )
    |> Repo.all()
  end
end
