defmodule DodoRouterWeb.SessionLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.LogsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, api_key} = RoutersFixtures.router_fixture(user)
    %{router: router, api_key: api_key}
  end

  describe "Index" do
    test "shows sessions list", %{conn: conn, router: router} do
      session_id = "session-#{System.unique_integer([:positive])}"
      LogsFixtures.log_with_session(router, session_id)
      LogsFixtures.log_with_session(router, session_id)

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "Sessions"
      assert html =~ session_id
    end

    test "shows empty state when no sessions", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "No sessions yet"
      assert html =~ "X-Session-Id"
    end

    test "shows request count per session", %{conn: conn, router: router} do
      session_id = "test-session"
      LogsFixtures.log_with_session(router, session_id)
      LogsFixtures.log_with_session(router, session_id)
      LogsFixtures.log_with_session(router, session_id)

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "3 requests"
    end

    test "raises when router doesn't belong to user", %{conn: conn} do
      {other_router, _} = RoutersFixtures.router_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/routers/#{other_router.id}/sessions")
      end
    end
  end

  describe "Show" do
    test "shows session details", %{conn: conn, router: router} do
      session_id = "session-#{System.unique_integer([:positive])}"
      LogsFixtures.log_with_session(router, session_id)

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions/#{session_id}")

      assert html =~ session_id
    end

    test "shows session name from logs", %{conn: conn, router: router} do
      session_id = "test-session"
      session_name = "My Test Session"
      LogsFixtures.log_with_session(router, session_id, %{session_name: session_name})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions/#{session_id}")

      assert html =~ session_name
    end

    test "allows editing session name", %{conn: conn, router: router} do
      session_id = "test-session"
      LogsFixtures.log_with_session(router, session_id)

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/sessions/#{session_id}")

      # Click edit button (has icon, no text)
      assert live |> element("button[phx-click='edit_name']") |> render_click()

      # Fill in new name
      new_name = "Updated Session Name"

      assert live
             |> form("form", %{"session_name" => new_name})
             |> render_submit()

      # Verify the name was updated
      assert render(live) =~ new_name

      # Verify in database
      logs = DodoRouter.Logs.list_logs_by_session(router, session_id)
      assert Enum.all?(logs, &(&1.session_name == new_name))
    end
  end
end
