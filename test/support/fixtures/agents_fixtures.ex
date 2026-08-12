defmodule DodoRouter.AgentsFixtures do
  @moduledoc """
  Test helpers for agent credentials.

  `agent_token_fixture/2` returns `{token, raw}` — the raw secret exists only
  on the mint, exactly as it does in production, so a test cannot accidentally
  reach for a value the real system never keeps.
  """

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Scopes

  def agent_token_fixture(user, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "name" => "Test agent",
        # Every scope by default, including the sensitive ones: a test that
        # cares about scoping should say so explicitly, and one that doesn't
        # should not silently depend on the production default.
        "scopes" => Scopes.names(),
        # Reach is required at mint time, so the fixture has to state one.
        # Tests about reach override it.
        "all_routers" => true
      })

    {:ok, token} = Agents.create_token(user, attrs)

    {token, token.token}
  end

  @doc "A token holding only the named scopes."
  def scoped_token_fixture(user, scopes, attrs \\ %{}) do
    agent_token_fixture(user, Map.merge(attrs, %{"scopes" => scopes}))
  end

  @doc "A token that reaches only the given routers."
  def token_for_routers_fixture(user, routers, attrs \\ %{}) do
    agent_token_fixture(
      user,
      Map.merge(attrs, %{
        "all_routers" => false,
        "router_ids" => Enum.map(routers, & &1.id)
      })
    )
  end
end
