defmodule DodoRouterWeb.LogLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.LogsFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists logs for all routers", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router, %{final_provider: "test-provider"})

      {:ok, _live, html} = live(conn, ~p"/logs")

      assert html =~ "Request Logs"
      assert html =~ log.final_provider
    end

    test "shows empty table when no logs", %{conn: conn, user: user} do
      {_router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, _live, html} = live(conn, ~p"/logs")

      assert html =~ "Request Logs"
    end

    test "can filter by router", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/logs")

      live
      |> form("form", router_id: router.id)
      |> render_change()

      assert_patch(live, ~p"/logs?router_id=#{router.id}")
    end

    test "shows status badges", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router, %{status: "success"})
      LogsFixtures.log_fixture(router, %{status: "error"})

      {:ok, _live, html} = live(conn, ~p"/logs")

      assert html =~ "success"
      assert html =~ "error"
    end
  end
end
