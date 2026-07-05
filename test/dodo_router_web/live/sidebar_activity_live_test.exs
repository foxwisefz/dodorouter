defmodule DodoRouterWeb.SidebarActivityLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  defp mount_sidebar(conn, user) do
    live_isolated(conn, DodoRouterWeb.SidebarActivityLive,
      session: %{"user_id" => user.id, "current_path" => "/routers"}
    )
  end

  test "shows the user's routers", %{conn: conn, user: user} do
    {router, _} = RoutersFixtures.router_fixture(user)
    {:ok, _live, html} = mount_sidebar(conn, user)

    assert html =~ router.name
  end

  test "picks up newly created routers without a page reload", %{conn: conn, user: user} do
    {:ok, live, html} = mount_sidebar(conn, user)
    assert html =~ "No routers yet"

    {:ok, _router, _key} = Routers.create_router(user, %{name: "Fresh Router"})

    assert render(live) =~ "Fresh Router"
    refute render(live) =~ "No routers yet"
  end

  test "drops deleted routers without a page reload", %{conn: conn, user: user} do
    {router, _} = RoutersFixtures.router_fixture(user)
    {:ok, live, html} = mount_sidebar(conn, user)
    assert html =~ router.name

    {:ok, _} = Routers.delete_router(router)

    refute render(live) =~ router.name
  end
end
