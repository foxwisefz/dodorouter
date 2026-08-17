defmodule DodoRouterWeb.AgentActivityLiveTest do
  @moduledoc """
  The page exists so a user can answer "what has an agent been doing with my
  traffic?". These tests are about that question, not about the layout.
  """

  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.Agents
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.RoutersFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)

    %{conn: log_in_user(conn, user), user: user, router: router}
  end

  defp record(user, router, attrs) do
    {:ok, call} =
      Agents.record_call(
        Enum.into(attrs, %{
          user_id: user.id,
          router_id: router.id,
          principal_kind: "oauth",
          principal_name: "claude-code",
          interface: "mcp",
          operation: "tools/call",
          outcome: "ok",
          http_status: 200
        })
      )

    call
  end

  test "an account with nothing connected says so rather than showing an empty table", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/agent-activity")

    assert render(view) =~ "Nothing connected yet"
    assert has_element?(view, "#connect-agent")
  end

  test "the connect command is the MCP one, since there is no key to mint", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent-activity")

    assert render(view) =~ "claude mcp add"
    assert render(view) =~ "/mcp"
  end

  test "a connected agent is listed with what it did", %{conn: conn, user: user, router: router} do
    record(user, router, tool: "list_logs")
    record(user, router, tool: "get_log", returned_bodies: true)

    {:ok, view, _html} = live(conn, ~p"/agent-activity")

    assert has_element?(view, "#client-#{Base.url_encode64("claude-code", padding: false)}")
    # Reading transcript text is the permission worth surfacing as exercised,
    # not merely granted.
    assert render(view) =~ "Read prompt or response text on 1 calls"
  end

  test "refused calls are visible without hunting for them", %{
    conn: conn,
    user: user,
    router: router
  } do
    record(user, router, tool: "create_eval", outcome: "denied", http_status: 403)

    {:ok, view, _html} = live(conn, ~p"/agent-activity")

    assert render(view) =~ "denied"

    view |> element("#filter-denied") |> render_click()

    assert render(view) =~ "create_eval"
  end

  test "filtering to allowed hides the refused rows", %{conn: conn, user: user, router: router} do
    record(user, router, tool: "list_logs")
    denied = record(user, router, tool: "create_eval", outcome: "denied", http_status: 403)

    {:ok, view, _html} = live(conn, ~p"/agent-activity")

    view |> element("#filter-ok") |> render_click()

    refute has_element?(view, "#call-#{denied.id}")
  end

  test "another user's agent activity is not visible", %{conn: conn} do
    stranger = AccountsFixtures.user_fixture()
    {stranger_router, _key} = RoutersFixtures.router_fixture(stranger)
    record(stranger, stranger_router, tool: "list_logs", principal_name: "someone-else")

    {:ok, view, _html} = live(conn, ~p"/agent-activity")

    refute render(view) =~ "someone-else"
  end
end
