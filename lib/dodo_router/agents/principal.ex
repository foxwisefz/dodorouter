defmodule DodoRouter.Agents.Principal do
  @moduledoc """
  Who is calling the agent surface, resolved from whatever credential they used.

  This is the seam the credential decision plugs into. Everything downstream —
  scope checks, audit rows, router ownership — reads this struct and never the
  credential itself, so adding OAuth access tokens later means adding one
  resolver, not editing every controller.
  """

  @enforce_keys [:kind, :user, :scopes]
  defstruct [
    :kind,
    :user,
    :scopes,
    :id,
    :name,
    :token,
    router_ids: [],
    all_routers: false
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          user: DodoRouter.Accounts.User.t(),
          scopes: [String.t()],
          id: String.t() | nil,
          name: String.t() | nil,
          token: DodoRouter.Agents.AgentToken.t() | nil,
          router_ids: [String.t()],
          all_routers: boolean()
        }

  alias DodoRouter.Agents.{AgentToken, Scopes}

  def from_token(%AgentToken{} = token, user) do
    %__MODULE__{
      kind: "agent_token",
      id: token.id,
      name: token.name,
      user: user,
      scopes: token.scopes,
      token: token,
      router_ids: token.router_ids || [],
      all_routers: token.all_routers
    }
  end

  def allows?(%__MODULE__{scopes: scopes}, required), do: Scopes.satisfied?(scopes, required)

  @doc """
  Whether this principal may act on the given router.

  Ownership is checked on every call rather than trusted from the stored list,
  so a router that changed hands cannot be reached through a token minted
  before the change. The list narrows what an owner granted; it never widens it.

  `all_routers` is the deliberately unbounded case — every router the owner has
  now *and later*, across all their apps — which is why it has to be chosen
  explicitly rather than being what an empty list happens to mean.
  """
  def allows_router?(%__MODULE__{} = principal, router) do
    router.user_id == principal.user.id and
      (principal.all_routers or router.id in principal.router_ids)
  end
end
