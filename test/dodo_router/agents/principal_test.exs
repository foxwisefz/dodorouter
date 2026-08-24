defmodule DodoRouter.Agents.PrincipalTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Principal

  import DodoRouter.AccountsFixtures
  import DodoRouter.RoutersFixtures

  defp context(scopes), do: %{client_id: "test-client", scope: scopes}

  describe "from_oauth/2 router narrowing" do
    test "no router scopes means every router the owner has" do
      user = user_fixture()
      principal = Principal.from_oauth(context(["logs:read"]), user)

      assert principal.all_routers
      assert principal.router_ids == []
    end

    test "router scopes narrow reach and survive into the scope list" do
      user = user_fixture()
      {router, _key} = router_fixture(user)

      scopes = ["logs:read", "router:" <> router.id]
      principal = Principal.from_oauth(context(scopes), user)

      refute principal.all_routers
      assert principal.router_ids == [router.id]
      # Kept verbatim so audit rows show exactly what the token carried.
      assert principal.scopes == scopes
    end
  end

  describe "the narrowing seam: token scopes through to router reach" do
    test "routers_for returns only the granted router" do
      user = user_fixture()
      {granted, _} = router_fixture(user)
      {other, _} = router_fixture(user)

      principal = Principal.from_oauth(context(["logs:read", "router:" <> granted.id]), user)

      reachable = Agents.routers_for(user, principal)
      assert Enum.map(reachable, & &1.id) == [granted.id]

      assert Principal.allows_router?(principal, granted)
      refute Principal.allows_router?(principal, other)
    end

    test "a granted router that changed hands is unreachable" do
      user = user_fixture()
      stranger = user_fixture()
      {theirs, _} = router_fixture(stranger)

      principal = Principal.from_oauth(context(["logs:read", "router:" <> theirs.id]), user)

      refute Principal.allows_router?(principal, theirs)
      assert Agents.routers_for(user, principal) == []
    end
  end
end
