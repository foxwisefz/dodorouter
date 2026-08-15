defmodule DodoRouter.Agents.Principal do
  @moduledoc """
  Who is calling the agent surface, resolved from whatever credential they used.

  The seam the credential decision plugs into. Everything downstream — scope
  checks, audit rows, router ownership — reads this struct and never the
  credential itself. That is what made replacing bearer agent tokens with OAuth
  a matter of adding one resolver rather than editing every caller, and it is
  why the struct keeps a `kind` and a router list even though only one resolver
  exists today.
  """

  @enforce_keys [:kind, :user, :scopes]
  defstruct [
    :kind,
    :user,
    :scopes,
    :id,
    :name,
    router_ids: [],
    all_routers: false
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          user: DodoRouter.Accounts.User.t(),
          scopes: [String.t()],
          id: String.t() | nil,
          name: String.t() | nil,
          router_ids: [String.t()],
          all_routers: boolean()
        }

  alias DodoRouter.Agents.Scopes

  @doc """
  Builds a principal from an attesto-verified access token.

  Reach is currently every router the owner has. An OAuth token carries scopes
  but no router list, so the per-router narrowing the retired agent tokens could
  express has no equivalent yet — see dodo_router-5m5.9.
  """
  def from_oauth(%{} = context, user) do
    %__MODULE__{
      kind: "oauth",
      id: nil,
      name: context[:client_id] || context["client_id"],
      user: user,
      scopes: context[:scope] || context["scope"] || [],
      router_ids: [],
      all_routers: true
    }
  end

  def allows?(%__MODULE__{scopes: scopes}, required), do: Scopes.satisfied?(scopes, required)

  @doc """
  Whether this principal may act on the given router.

  Ownership is checked on every call rather than trusted from the principal,
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
