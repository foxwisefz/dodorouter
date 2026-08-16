defmodule DodoRouterWeb.TokenAttributionSeamTest do
  use DodoRouterWeb.ConnCase, async: true

  import Ecto.Query

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Repo
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  # Unit tests cover the parser; this covers the seam — a real dispatch
  # writes the attribution onto the log row, computed from the in-memory
  # body against the usage the provider actually reported.
  test "a served request logs its context breakdown", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)

    {:ok, _step} =
      Routers.create_routing_step(router, %{
        position: 0,
        provider: "test_provider",
        model: "test-model",
        provider_key_id: key.id
      })

    conn
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> put_req_header("content-type", "application/json")
    |> post("/r/#{router.slug}/v1/chat/completions", %{
      "model" => "test-model",
      "messages" => [
        %{"role" => "system", "content" => "be terse"},
        %{"role" => "user", "content" => "hello there"}
      ]
    })
    |> json_response(200)

    log = Repo.one!(from(l in RequestLog, where: l.router_id == ^router.id))

    assert %{"buckets" => buckets, "basis_tokens" => basis} = log.token_attribution
    # TestProvider reports prompt_tokens: 10 — the buckets sum to exactly
    # what was billed.
    assert basis == 10

    total = buckets |> Enum.map(fn {_name, b} -> b["allocated_tokens"] end) |> Enum.sum()
    assert total == 10
    assert buckets["system"]["allocated_tokens"] > 0
    assert buckets["history"]["allocated_tokens"] > 0
  end

  describe "log page panel" do
    import Phoenix.LiveViewTest

    setup :register_and_log_in_user

    test "shows the context breakdown when the row carries one", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        DodoRouter.LogsFixtures.log_fixture(router, %{
          token_attribution: %{
            "version" => 1,
            "basis_tokens" => 100,
            "total_chars" => 400,
            "cache_frontier" => "cache_control",
            "buckets" => %{
              "system" => %{"chars" => 100, "allocated_tokens" => 25, "cached_tokens" => 25},
              "tools" => %{"chars" => 0, "allocated_tokens" => 0, "cached_tokens" => 0},
              "history" => %{"chars" => 60, "allocated_tokens" => 15, "cached_tokens" => 0},
              "tool_results" => %{
                "chars" => 240,
                "allocated_tokens" => 60,
                "cached_tokens" => 0,
                "by_tool" => %{"Read" => 60}
              },
              "file_contents" => %{"chars" => 0, "allocated_tokens" => 0, "cached_tokens" => 0}
            }
          }
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}")

      assert has_element?(live, "#token-attribution", "Tool results")
      assert has_element?(live, "#token-attribution", "Read")
      # Zero buckets stay out of the panel.
      refute has_element?(live, "#token-attribution", "File contents")
    end
  end
end
