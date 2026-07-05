defmodule DodoRouterWeb.LogLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.{Logs, RoutersFixtures}
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

    test "shows empty state when no logs", %{conn: conn, user: user} do
      {_router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, html} = live(conn, ~p"/logs")

      assert html =~ "Request Logs"
      assert has_element?(live, "#logs-empty")
      assert render(live) =~ "No requests yet"
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

    test "favorites filter shows only favorited logs", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      LogsFixtures.log_fixture(router, %{favorite: true, final_provider: "fav-provider"})
      LogsFixtures.log_fixture(router, %{favorite: false, final_provider: "other-provider"})

      {:ok, _live, html} = live(conn, ~p"/logs?favorites=true")

      assert html =~ "fav-provider"
      refute html =~ "other-provider"
    end

    test "can toggle favorite from index", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/logs")

      live |> render_click("toggle_favorite", %{"id" => log.id})

      assert Logs.get_log!(user, log.id).favorite
    end
  end

  describe "Show favorite toggle" do
    test "can favorite and unfavorite a log", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "#favorite-button[data-favorited='false']")

      live |> element("#favorite-button") |> render_click()

      assert has_element?(live, "#favorite-button[data-favorited='true']")

      live |> element("#favorite-button") |> render_click()

      assert has_element?(live, "#favorite-button[data-favorited='false']")
    end
  end

  describe "Show" do
    test "renders conversation with cache tokens without crashing", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          final_provider: "moonshot",
          final_model: "kimi-k2.7",
          prompt_tokens: 500,
          completion_tokens: 50,
          total_tokens: 550,
          cache_read_tokens: 400,
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "system", "content" => String.duplicate("x", 1200)},
                %{"role" => "user", "content" => "hello"},
                %{"role" => "assistant", "content" => "hi"}
              ]
            }),
          response_body:
            Jason.encode!(%{
              "choices" => [%{"message" => %{"role" => "assistant", "content" => "response"}}],
              "usage" => %{
                "prompt_tokens" => 500,
                "completion_tokens" => 50,
                "total_tokens" => 550,
                "prompt_tokens_details" => %{"cached_tokens" => 400}
              }
            })
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "cached"
      assert html =~ "response"
    end

    test "renders per-step response body in fallback trace", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
        %{
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-20250514",
          "status" => "error",
          "latency_ms" => 100,
          "error" => "rate_limited"
        },
        %{
          "provider" => "openai",
          "model" => "gpt-4o",
          "status" => "success",
          "latency_ms" => 200,
          "response_body" =>
            Jason.encode!(%{"choices" => [%{"message" => %{"content" => "hello"}}]})
        }
      ]

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: attempted_steps,
          status: "fallback"
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      html =
        live
        |> element("button[phx-value-tab=\"fallback_trace\"]")
        |> render_click()

      assert html =~ "Response Body"
      assert html =~ "hello"
    end

    test "renders per-step response headers in fallback trace", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
        %{
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-20250514",
          "status" => "error",
          "latency_ms" => 100,
          "error" => "rate_limited"
        },
        %{
          "provider" => "openai",
          "model" => "gpt-4o",
          "status" => "success",
          "latency_ms" => 200,
          "response_headers" => [
            ["x-request-id", "req-123"],
            ["content-type", "application/json"]
          ]
        }
      ]

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: attempted_steps,
          status: "fallback"
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      html =
        live
        |> element("button[phx-value-tab=\"fallback_trace\"]")
        |> render_click()

      assert html =~ "Response Headers"
      assert html =~ "x-request-id"
      assert html =~ "req-123"
    end

    test "renders error body for failed step", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
        %{
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-20250514",
          "status" => "error",
          "latency_ms" => 100,
          "error" => "rate_limited",
          "error_body" => "{\"error\":\"rate limited\"}"
        },
        %{
          "provider" => "openai",
          "model" => "gpt-4o",
          "status" => "success",
          "latency_ms" => 300,
          "response_body" =>
            Jason.encode!(%{"choices" => [%{"message" => %{"content" => "fallback response"}}]})
        }
      ]

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: attempted_steps,
          status: "fallback"
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      html =
        live
        |> element("button[phx-value-tab=\"fallback_trace\"]")
        |> render_click()

      assert html =~ "Error Response"
      assert html =~ "rate limited"
      assert html =~ "Response Body"
      assert html =~ "fallback response"
    end

    test "hides response body and headers when not present", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
        %{
          "provider" => "openai",
          "model" => "gpt-4o",
          "status" => "success",
          "latency_ms" => 200
        }
      ]

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: attempted_steps,
          status: "success"
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      refute html =~ "Response Body"
      refute html =~ "Response Headers"
    end

    test "shows plan_type badge for coding and standard variants", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
        %{
          "provider" => "moonshot",
          "model" => "kimi-k2.5",
          "status" => "success",
          "latency_ms" => 300,
          "plan_type" => "coding"
        },
        %{
          "provider" => "zai",
          "model" => "glm-5.1",
          "status" => "success",
          "latency_ms" => 250,
          "plan_type" => "standard"
        }
      ]

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: attempted_steps,
          status: "success"
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      html =
        live
        |> element("button[phx-value-tab=\"fallback_trace\"]")
        |> render_click()

      assert html =~ "coding"
      assert html =~ "standard"
    end

    test "hides plan_type badge when not present", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
        %{
          "provider" => "openai",
          "model" => "gpt-4o",
          "status" => "success",
          "latency_ms" => 200
        }
      ]

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: attempted_steps,
          status: "success"
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      refute html =~ "standard"
      refute html =~ "coding"
    end
  end
end
