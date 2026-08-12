defmodule DodoRouter.Agents.Principal do
  @moduledoc """
  Who is calling the agent surface, resolved from whatever credential they used.

  This is the seam the credential decision plugs into. Everything downstream —
  scope checks, audit rows, router ownership — reads this struct and never the
  credential itself, so adding OAuth access tokens later means adding one
  resolver, not editing every controller.
  """

  @enforce_keys [:kind, :user, :scopes]
  defstruct [:kind, :user, :scopes, :id, :name, :token, :router_id]

  @type t :: %__MODULE__{
          kind: String.t(),
          user: DodoRouter.Accounts.User.t(),
          scopes: [String.t()],
          id: String.t() | nil,
          name: String.t() | nil,
          token: DodoRouter.Agents.AgentToken.t() | nil,
          # Set when the credential is pinned to one router; nil means every
          # router its owner has.
          router_id: String.t() | nil
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
      router_id: token.router_id
    }
  end

  def allows?(%__MODULE__{scopes: scopes}, required), do: Scopes.satisfied?(scopes, required)

  @doc """
  Whether this principal may act on the given router.

  Two conditions, not one: the router must belong to the credential's owner,
  and — when the credential was pinned to a single router — it must be that
  one. The pin is what makes a token handed to one product unable to read
  another product's traffic, even though the same person owns both.
  """
  def allows_router?(%__MODULE__{} = principal, router) do
    router.user_id == principal.user.id and
      (is_nil(principal.router_id) or principal.router_id == router.id)
  end
end
