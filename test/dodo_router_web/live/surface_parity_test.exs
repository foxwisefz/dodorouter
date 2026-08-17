defmodule DodoRouterWeb.SurfaceParityTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  defp attribution(tokens) do
    %{
      "version" => 1,
      "basis_tokens" => tokens,
      "total_chars" => tokens * 4,
      "cache_frontier" => nil,
      "buckets" => %{
        "system" => %{"chars" => 0, "allocated_tokens" => 0, "cached_tokens" => 0},
        "tools" => %{"chars" => 0, "allocated_tokens" => 0, "cached_tokens" => 0},
        "history" => %{
          "chars" => tokens * 2,
          "allocated_tokens" => div(tokens, 2),
          "cached_tokens" => 0
        },
        "tool_results" => %{
          "chars" => tokens * 2,
          "allocated_tokens" => tokens - div(tokens, 2),
          "cached_tokens" => 0,
          "by_tool" => %{"Read" => tokens - div(tokens, 2)}
        },
        "file_contents" => %{"chars" => 0, "allocated_tokens" => 0, "cached_tokens" => 0}
      }
    }
  end

  test "the log page says why a replay cost nothing and links its original", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    original = LogsFixtures.log_fixture(router, %{idempotency_key: "row-42"})

    replay =
      LogsFixtures.log_fixture(router, %{
        idempotency_key: "row-42",
        idempotent_replay_of_id: original.id
      })

    {:ok, live, html} = live(conn, ~p"/logs/#{replay.id}")

    assert html =~ "row-42"
    assert has_element?(live, "#idempotent-replay-link[href='/logs/#{original.id}']")

    # The original shows the key but no replay link.
    {:ok, live, html} = live(conn, ~p"/logs/#{original.id}")
    assert html =~ "row-42"
    refute has_element?(live, "#idempotent-replay-link")
  end

  test "the session page shows the token-attribution rollup", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)

    LogsFixtures.log_fixture(router, %{session_id: "q-1", token_attribution: attribution(100)})
    LogsFixtures.log_fixture(router, %{session_id: "q-1", token_attribution: attribution(50)})

    {:ok, live, html} = live(conn, ~p"/routers/#{router.id}/sessions/q-1")

    assert has_element?(live, "#session-token-attribution", "Tool results")
    assert has_element?(live, "#session-token-attribution", "Read")
    # Summed across both rows.
    assert html =~ "Summed across 2 requests"
    # Zero buckets stay out.
    refute has_element?(live, "#session-token-attribution", "File contents")
  end
end
