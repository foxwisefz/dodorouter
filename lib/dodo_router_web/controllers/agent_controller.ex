defmodule DodoRouterWeb.AgentController do
  @moduledoc """
  The unscoped entry point: what this credential is, and what it can reach.

  Every other agent endpoint lives under `/r/:router_slug`, which left a hole —
  an agent handed a base URL and a token had no way to learn its first slug and
  had to be told one out of band. That made `GET /r/:slug/agent` self-onboarding
  only for a caller who already knew the thing it was meant to teach them.
  """

  use DodoRouterWeb, :controller

  import DodoRouterWeb.AgentApi

  alias DodoRouter.Agents

  def index(conn, _params) do
    principal = principal(conn)
    routers = Agents.routers_for(principal.user, principal.token)
    base = DodoRouterWeb.Endpoint.url()

    json(conn, %{
      token: %{
        name: principal.name,
        scopes: principal.scopes,
        expires_at: principal.token && principal.token.expires_at,
        reaches_all_routers: principal.all_routers
      },
      routers: Enum.map(routers, &router_entry(&1, base)),
      next: next_step(routers, base),
      # Scopes are named here as well as on the token, because a 403 later is
      # easier to act on when the caller already knows the vocabulary.
      scopes: Enum.map(DodoRouter.Agents.Scopes.all(), &scope_entry/1)
    })
  end

  defp router_entry(router, base) do
    %{
      id: router.id,
      name: router.name,
      slug: router.slug,
      base_url: "#{base}/r/#{router.slug}",
      guide: "#{base}/r/#{router.slug}/agent"
    }
  end

  # A token that reaches nothing is a real state — the routers it named may
  # have been deleted — and saying so beats returning an empty list with no
  # explanation of what to do about it.
  defp next_step([], _base),
    do:
      "This token reaches no routers. Grant it some, or create a router, at the Agent tokens page."

  defp next_step([router | _], base),
    do: "GET #{base}/r/#{router.slug}/agent for the evaluation workflow."

  defp scope_entry(scope) do
    %{
      name: scope.name,
      description: scope.description,
      sensitive: scope.sensitive?
    }
  end
end
