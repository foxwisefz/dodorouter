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

    test "pluralizes counts correctly with a single session and request", %{
      conn: conn,
      router: router
    } do
      LogsFixtures.log_with_session(router, "solo-session")

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "1 session"
      refute html =~ "1 sessions"
      assert html =~ "1 request"
      refute html =~ "1 requests"
    end

    test "shows request count per session", %{conn: conn, router: router} do
      session_id = "test-session"
      LogsFixtures.log_with_session(router, session_id)
      LogsFixtures.log_with_session(router, session_id)
      LogsFixtures.log_with_session(router, session_id)

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "3 requests"
    end

    test "shows spend per session", %{conn: conn, router: router} do
      LogsFixtures.log_with_session(router, "paid-session", %{
        estimated_cost_usd: Decimal.new("2.50"),
        list_cost_usd: Decimal.new("2.50")
      })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "$2.50"
    end

    test "shows would-be cost for plan-covered sessions", %{conn: conn, router: router} do
      LogsFixtures.log_with_session(router, "plan-session", %{
        estimated_cost_usd: Decimal.new("0"),
        list_cost_usd: Decimal.new("12.00")
      })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "~$12.00"
      assert html =~ "at API rates"
    end

    test "raises when router doesn't belong to user", %{conn: conn} do
      {other_router, _} = RoutersFixtures.router_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/routers/#{other_router.id}/sessions")
      end
    end

    test "page 1 shows a working Next link and no Prev link when more pages exist", %{
      conn: conn,
      router: router
    } do
      for i <- 1..21 do
        LogsFixtures.log_with_session(router, "session-#{i}")
      end

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/sessions")

      refute has_element?(live, "#sessions-prev-page")
      assert has_element?(live, "#sessions-next-page")
    end

    test "page 2 shows a Prev link", %{conn: conn, router: router} do
      for i <- 1..21 do
        LogsFixtures.log_with_session(router, "session-#{i}")
      end

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/sessions?page=2")

      assert has_element?(live, "#sessions-prev-page")
    end

    test "receiving a log_created event on page 2 keeps the user on page 2", %{
      conn: conn,
      router: router
    } do
      for i <- 1..21 do
        LogsFixtures.log_with_session(router, "session-#{i}")
      end

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/sessions?page=2")

      assert live |> element("span", "Page 2") |> has_element?()

      send(live.pid, {:log_created, %{}})

      html = render(live)
      assert html =~ "Page 2"
      # Page 2 should still show only per_page (20) worth of sessions, not
      # every session in the router.
      session_rows = Regex.scan(~r/session-\d+/, html) |> List.flatten() |> Enum.uniq()
      assert length(session_rows) <= 20
    end

    test "header shows total session count, not just the current page size", %{
      conn: conn,
      router: router
    } do
      for i <- 1..21 do
        LogsFixtures.log_with_session(router, "session-#{i}")
      end

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "21 sessions"
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

    test "shows total spend and per-request cost", %{conn: conn, router: router} do
      session_id = "cost-session"

      LogsFixtures.log_with_session(router, session_id, %{
        estimated_cost_usd: Decimal.new("1.00"),
        list_cost_usd: Decimal.new("1.00")
      })

      LogsFixtures.log_with_session(router, session_id, %{
        estimated_cost_usd: Decimal.new("1.50"),
        list_cost_usd: Decimal.new("1.50")
      })

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}/sessions/#{session_id}")

      assert html =~ "Cost"
      # Session total
      assert has_element?(live, "#session-cost", "$2.50")
      # Per-request cost on the timeline
      assert html =~ "$1.50"
    end

    test "shows would-be cost when traffic is plan-covered", %{conn: conn, router: router} do
      session_id = "plan-cost-session"

      LogsFixtures.log_with_session(router, session_id, %{
        estimated_cost_usd: Decimal.new("0"),
        list_cost_usd: Decimal.new("12.00")
      })

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}/sessions/#{session_id}")

      assert has_element?(live, "#session-cost", "$0")
      assert html =~ "~$12.00"
      assert html =~ "at API rates"
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

  describe "cache regression" do
    # Reads pinned at 38k while the conversation grows — the AGENTS.md
    # breakpoint signature.
    defp regressed_session(router, session_id) do
      turn(router, session_id, 20_000, 400, ["hello"])
      turn(router, session_id, 38_000, 400, ["hello", "and now the long part"])

      for {prompt, turns} <- [
            {9_000, ["hello", "and now the LONG part"]},
            {12_000, ["hello", "and now the LONG part", "more"]},
            {15_000, ["hello", "and now the LONG part", "more", "still more"]},
            {18_000, ["hello", "and now the LONG part", "more", "still more", "yet more"]}
          ] do
        turn(router, session_id, 38_000, prompt, turns)
      end
    end

    defp healthy_session(router, session_id) do
      for {read, n} <- Enum.with_index([10_000, 12_000, 14_000, 16_000]) do
        turn(router, session_id, read, 300, Enum.map(0..n, &"turn #{&1}"))
      end
    end

    defp turn(router, session_id, read, prompt, contents) do
      body =
        Jason.encode!(%{
          "messages" => Enum.map(contents, &%{"role" => "user", "content" => &1})
        })

      LogsFixtures.log_with_session(router, session_id, %{
        prompt_tokens: prompt,
        cache_read_tokens: read,
        final_provider: "anthropic",
        final_model: "claude-opus-5",
        request_body: body
      })
    end

    test "a regressed session is marked in the list", %{conn: conn, router: router} do
      regressed_session(router, "broken-session")

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      assert html =~ "Cache stopped hitting"
    end

    test "a healthy session is not marked", %{conn: conn, router: router} do
      healthy_session(router, "fine-session")

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions")

      refute html =~ "Cache stopped hitting"
    end

    test "the session view explains what happened and where", %{conn: conn, router: router} do
      regressed_session(router, "broken-session")

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}/sessions/broken-session")

      assert html =~ "The prompt cache stopped hitting"
      # The turn that diverged carries the marker, and the notice links to it.
      diverged = Enum.at(DodoRouter.Logs.list_logs_by_session(router, "broken-session"), 2)
      assert has_element?(live, "a[href='#turn-#{diverged.id}']")
      assert has_element?(live, "#turn-#{diverged.id}.ring-warning\\/60")
    end

    test "the notice shows what changed inside the shared prefix", %{conn: conn, router: router} do
      regressed_session(router, "broken-session")

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/sessions/broken-session")

      assert has_element?(live, "details summary", "What changed in the cached prefix")
      assert has_element?(live, "details ins", "LONG")
      assert has_element?(live, "details del", "long")
    end

    test "a healthy session view says nothing about the cache", %{conn: conn, router: router} do
      healthy_session(router, "fine-session")

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/sessions/fine-session")

      refute html =~ "The prompt cache stopped hitting"
    end
  end
end
