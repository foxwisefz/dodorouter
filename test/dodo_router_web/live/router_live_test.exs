defmodule DodoRouterWeb.RouterLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists user's routers", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user, %{name: "My Router"})

      {:ok, _live, html} = live(conn, ~p"/routers")

      assert html =~ "Routers"
      assert html =~ router.name
      assert html =~ router.slug
    end

    test "shows empty state when no routers", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/routers")

      assert html =~ "No routers yet"
      assert html =~ "Create Router"
    end

    test "opens new router modal", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/routers")

      assert live |> element("a", "New Router") |> render_click() =~ "New Router"
    end

    test "creates a new router", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/routers/new")

      live
      |> form("#router-form", router: %{name: "Test Router", slug: "test-router"})
      |> render_submit()

      assert render(live) =~ "Save your API key!"
      assert render(live) =~ "Test Router"
    end

    test "deletes a router", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user, %{name: "Delete Me"})

      {:ok, live, html} = live(conn, ~p"/routers")
      assert html =~ "Delete Me"

      assert live
             |> element("a[phx-click=\"delete\"][phx-value-id=\"#{router.id}\"]")
             |> render_click()

      refute render(live) =~ "Delete Me"
    end

    test "does not show other user's routers", %{conn: conn} do
      {other_router, _} = RoutersFixtures.router_fixture()

      {:ok, _live, html} = live(conn, ~p"/routers")

      refute html =~ other_router.name
    end
  end
end
