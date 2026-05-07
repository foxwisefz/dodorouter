defmodule DodoRouterWeb.RouterShowLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.LogsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, api_key} = RoutersFixtures.router_fixture(user)
    %{router: router, api_key: api_key}
  end

  describe "Show" do
    test "shows router details", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ router.name
      assert html =~ router.slug
    end

    test "shows API usage snippet", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "curl"
      assert html =~ router.slug
    end

    test "shows recent logs section", %{conn: conn, router: router} do
      LogsFixtures.log_fixture(router, %{final_provider: "test-provider"})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "test-provider"
    end

    test "can switch snippet tabs", %{conn: conn, router: router} do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}")

      html =
        live
        |> element("button[phx-click=\"set_snippet_tab\"][phx-value-tab=\"python\"]")
        |> render_click()

      assert html =~ "openai" or html =~ "python"
    end

    test "can toggle fail_on_context_overflow setting", %{conn: conn, router: router, user: user} do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}")

      assert router.fail_on_context_overflow == false

      html =
        live
        |> element("form[phx-change=\"toggle_fail_on_context_overflow\"]")
        |> render_change(%{"fail_on_context_overflow" => "true"})

      assert html =~ "Skip fallback on context overflow"

      updated_router = DodoRouter.Routers.get_router!(user, router.id)
      assert updated_router.fail_on_context_overflow == true
    end

    test "raises when router doesn't belong to user", %{conn: conn} do
      {other_router, _} = RoutersFixtures.router_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/routers/#{other_router.id}")
      end
    end
  end

  describe "Routing" do
    test "shows routing configuration page", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/routing")

      assert html =~ "Routing"
    end

    test "shows empty state when no routing steps", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/routing")

      assert html =~ "Add Step" or html =~ "No routing"
    end
  end
end
