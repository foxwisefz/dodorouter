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

      {:ok, live, html} = live(conn, ~p"/dashboard")

      assert html =~ "Total Spend"
      assert html =~ "Success Rate"
      assert has_element?(live, "#kpi-requests")
      assert has_element?(live, "#spend-chart")
      assert has_element?(live, "#requests-chart")
      assert has_element?(live, "#latency-chart")
      assert has_element?(live, "#provider-share")
    end

    test "can select different router", %{conn: conn, user: user} do
      {router1, _} = RoutersFixtures.router_fixture(user, %{name: "Router One"})
      {router2, _} = RoutersFixtures.router_fixture(user, %{name: "Router Two"})

      {:ok, live, _html} = live(conn, ~p"/dashboard")

      assert render(live) =~ router1.name

      live
      |> element("button[phx-value-router_id='#{router2.id}']")
      |> render_click()

      assert_patch(live, ~p"/dashboard?router_id=#{router2.id}&range=24h")
    end

    test "can change the time range", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/dashboard")

      live
      |> element("#range-picker button[phx-value-range='7d']")
      |> render_click()

      assert_patch(live, ~p"/dashboard?range=7d&router_id=#{router.id}")
      assert render(live) =~ "Last 7 days"
    end

    test "can toggle spend chart to table view", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/dashboard")

      live
      |> element("button[phx-click='spend_view'][phx-value-view='table']")
      |> render_click()

      refute has_element?(live, "#spend-chart")
    end
  end
end
