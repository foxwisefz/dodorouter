defmodule DodoRouterWeb.DashboardLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.LogsFixtures

  setup :register_and_log_in_user

  describe "Dashboard" do
    test "shows empty state when no routers", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/dashboard")

      assert html =~ "Welcome to DodoRouter"
      assert html =~ "Create Router"
    end

    test "shows dashboard with router", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, _live, html} = live(conn, ~p"/dashboard")

      assert html =~ "Dashboard"
      assert html =~ router.name
    end

    test "shows stats when logs exist", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, _live, html} = live(conn, ~p"/dashboard")

      assert html =~ "Total Requests"
      assert html =~ "Success Rate"
    end

    test "can select different router", %{conn: conn, user: user} do
      {router1, _} = RoutersFixtures.router_fixture(user, %{name: "Router One"})
      {router2, _} = RoutersFixtures.router_fixture(user, %{name: "Router Two"})

      {:ok, live, _html} = live(conn, ~p"/dashboard")

      assert render(live) =~ router1.name

      live
      |> element("button[phx-value-router_id='#{router2.id}']")
      |> render_click()

      assert_patch(live, ~p"/dashboard?router_id=#{router2.id}")
    end
  end
end
