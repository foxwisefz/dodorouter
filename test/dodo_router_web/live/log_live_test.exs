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

  describe "Show" do
    test "renders per-step response body in routing chain", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
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
          status: "success"
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      html =
        live
        |> element("button[phx-value-tab=performance]")
        |> render_click()

      assert html =~ "Response Body"
      assert html =~ "hello"
    end

    test "renders per-step response headers in routing chain", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      attempted_steps = [
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
          status: "success"
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      html =
        live
        |> element("button[phx-value-tab=performance]")
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
        |> element("button[phx-value-tab=performance]")
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
        |> element("button[phx-value-tab=performance]")
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
