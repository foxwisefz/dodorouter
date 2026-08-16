defmodule DodoRouterWeb.DashboardLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Repo

  setup :register_and_log_in_user

  defp backdate(log, hours) do
    ts = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

    {1, _} =
      Repo.update_all(from(l in RequestLog, where: l.id == ^log.id), set: [inserted_at: ts])

    log
  end

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

    test "can switch spend to list-price basis for plan traffic", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      # Subscription traffic: $0 actual, non-zero list price
      LogsFixtures.log_fixture(router, %{
        final_provider: "openai-codex",
        final_model: "chatgpt-5.5",
        estimated_cost_usd: Decimal.new("0"),
        list_cost_usd: Decimal.new("0.42")
      })

      {:ok, live, html} = live(conn, ~p"/dashboard")

      # Actual basis: plan model has no spend, toggle is offered
      assert has_element?(live, "#cost-basis-picker")
      assert html =~ "saved by plans"

      live
      |> element("#cost-basis-picker button[phx-value-basis='list']")
      |> render_click()

      html = render(live)
      assert html =~ "List Value"
      assert html =~ "chatgpt-5.5"
    end

    test "KPI tiles show a signed delta against the immediately preceding window", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      # previous 24h window (24-48h ago): the baseline to compare against
      for _ <- 1..2 do
        LogsFixtures.log_fixture(router, %{
          latency_ms: 1000,
          estimated_cost_usd: Decimal.new("0.0100")
        })
        |> backdate(30)
      end

      # current 24h window: more requests, more spend, slower
      for _ <- 1..4 do
        LogsFixtures.log_fixture(router, %{
          latency_ms: 4000,
          estimated_cost_usd: Decimal.new("0.0200")
        })
      end

      {:ok, live, html} = live(conn, ~p"/dashboard")

      assert has_element?(live, "#kpi-spend [data-kpi-delta]")
      assert has_element?(live, "#kpi-requests [data-kpi-delta]")
      assert has_element?(live, "#kpi-success [data-kpi-delta]")
      assert has_element?(live, "#kpi-latency [data-kpi-delta]")
      assert html =~ "vs prev 24h"
    end

    test "omits the delta rather than fabricate one when there is no prior window", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/dashboard")

      assert has_element?(live, "#kpi-spend", "no prior data")
      refute has_element?(live, "[data-kpi-delta]", "%")
    end

    test "hides cost-basis toggle when no list pricing recorded", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router, %{estimated_cost_usd: Decimal.new("0.10")})

      {:ok, live, _html} = live(conn, ~p"/dashboard")

      refute has_element?(live, "#cost-basis-picker")
    end

    test "lists recent sessions with stats", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      LogsFixtures.log_fixture(router, %{
        session_id: "sess-abc",
        session_name: "Refactor run",
        estimated_cost_usd: Decimal.new("0.25")
      })

      {:ok, live, html} = live(conn, ~p"/dashboard")

      assert has_element?(live, "#recent-sessions")
      assert html =~ "Refactor run"
      refute has_element?(live, "#sessions-config-hint")
    end

    test "shows session config hint when router never saw a session", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, live, html} = live(conn, ~p"/dashboard")

      assert has_element?(live, "#sessions-config-hint")
      assert html =~ "x-session-id"
      assert html =~ "x-session-name"
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
