defmodule DodoRouterWeb.ApiKeysLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.Accounts.Scope
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  test "creates an additional named key without invalidating the original and reveals it once", %{
    conn: conn,
    user: user
  } do
    {router, original} = RoutersFixtures.router_fixture(user)
    {:ok, view, _} = live(conn, ~p"/api-keys")

    assert has_element?(view, "#copy-endpoint-#{router.id}[phx-hook=CopyButton]")
    view |> form("#create-key-#{router.id}", api_key: %{name: "Production"}) |> render_submit()

    assert has_element?(view, "#new-api-key")
    assert has_element?(view, "#copy-new-api-key[phx-hook=CopyButton][data-copy]")
    assert length(Routers.list_api_keys(Scope.for_user(user), router.id)) == 2
    assert Routers.get_router_by_api_key(original).id == router.id
    view |> element("#dismiss-api-key") |> render_click()
    refute has_element?(view, "#new-api-key")
    {:ok, refreshed, _} = live(conn, ~p"/api-keys")
    refute has_element?(refreshed, "#new-api-key")
  end

  test "invalid names do not create a key", %{conn: conn, user: user} do
    {router, _} = RoutersFixtures.router_fixture(user)
    {:ok, view, _} = live(conn, ~p"/api-keys")

    view |> form("#create-key-#{router.id}", api_key: %{name: "   "}) |> render_submit()

    assert length(Routers.list_api_keys(Scope.for_user(user), router.id)) == 1
    assert has_element?(view, "#create-key-#{router.id} p", "can't be blank")
    refute has_element?(view, "#new-api-key")
  end

  test "revoking one key requires confirmation and leaves other keys working", %{
    conn: conn,
    user: user
  } do
    {router, original} = RoutersFixtures.router_fixture(user)
    scope = Scope.for_user(user)
    {:ok, key, secret} = Routers.create_api_key(scope, router.id, %{name: "Laptop"})
    {:ok, view, _} = live(conn, ~p"/api-keys")

    view |> element("#revoke-key-#{key.id}") |> render_click()
    assert has_element?(view, "#confirm-revoke-#{key.id}")
    assert Routers.get_router_by_api_key(secret).id == router.id
    view |> element("#cancel-revoke-#{key.id}") |> render_click()
    refute has_element?(view, "#confirm-revoke-#{key.id}")
    view |> element("#revoke-key-#{key.id}") |> render_click()
    view |> element("#confirm-revoke-#{key.id}") |> render_click()

    refute has_element?(view, "#api-key-#{key.id}")
    assert is_nil(Routers.get_router_by_api_key(secret))
    assert Routers.get_router_by_api_key(original).id == router.id
  end

  test "only lists owned routers and labels usage as router-wide", %{conn: conn, user: user} do
    {router, _} = RoutersFixtures.router_fixture(user)
    {other, _} = RoutersFixtures.router_fixture()
    DodoRouter.LogsFixtures.log_fixture(router)
    {:ok, view, _} = live(conn, ~p"/api-keys")

    assert has_element?(
             view,
             "#router-#{router.id} [data-router-requests-24h='1']",
             "Router activity"
           )

    refute has_element?(view, "#router-#{other.id}")
  end
end
