defmodule DodoRouterWeb.RouterLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists user's routers", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user, %{name: "My Router"})

      {:ok, _live, html} = live(conn, ~p"/routers")

      assert html =~ "Routers"
      assert html =~ router.name
      assert html =~ router.slug
    end

    test "cards show 24h request count, error rate and a sparkline", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user, %{name: "Busy Router"})

      for _ <- 1..3 do
        DodoRouter.LogsFixtures.log_fixture(router, %{status: "success"})
      end

      DodoRouter.LogsFixtures.log_fixture(router, %{status: "error"})

      {:ok, _live, html} = live(conn, ~p"/routers")

      assert html =~ ~s(data-router-requests="4")
      assert html =~ ~s(data-router-errors="1")
      assert html =~ "last 24h"
    end

    test "shows empty state when no routers", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/routers")

      assert html =~ "No routers yet"
      assert html =~ "Create Router"
    end

    test "opens new router modal", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/routers")

      assert live |> element("a", "New Router") |> render_click() =~ "New Router"
    end

    test "creates a new router", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/routers/new")

      live
      |> form("#router-form", router: %{name: "Test Router"})
      |> render_submit()

      # Creation drops the user straight into the new router's page,
      # where the one-time key banner (with copy button) is shown.
      {path, flash} = assert_redirect(live)
      assert path =~ ~r"^/routers/[0-9a-f-]+$"
      assert flash["new_api_key"]
    end

    test "invisible slug errors surface in the create modal", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/routers/new")

      html =
        live
        |> form("#router-form", router: %{name: "ab"})
        |> render_submit()

      # "ab" derives a 2-char slug, which fails the min-length validation on
      # a field the form doesn't render — the error must still be visible.
      assert html =~ "URL name"
    end

    test "deletes a router", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user, %{name: "Delete Me"})

      {:ok, live, html} = live(conn, ~p"/routers")
      assert html =~ "Delete Me"

      assert live
             |> element("a[phx-click=\"delete\"][phx-value-id=\"#{router.id}\"]")
             |> render_click()

      refute render(live) =~ "Delete Me"
    end

    test "does not show other user's routers", %{conn: conn} do
      {other_router, _} = RoutersFixtures.router_fixture()

      {:ok, _live, html} = live(conn, ~p"/routers")

      refute html =~ other_router.name
    end
  end

  describe "Show" do
    test "latency stat shows p95 with p50 subtext, not a bare mean", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      for _ <- 1..20 do
        DodoRouter.LogsFixtures.log_fixture(router, %{latency_ms: 100})
      end

      DodoRouter.LogsFixtures.log_fixture(router, %{latency_ms: 10_000})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "p95 Latency"
      refute html =~ "Avg Latency"
    end

    test "routing steps show their share of traffic and error rate", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, step_a} =
        DodoRouter.Routers.create_routing_step(router, %{
          provider: "zai",
          model: "glm-4.6"
        })

      {:ok, step_b} =
        DodoRouter.Routers.create_routing_step(router, %{
          provider: "moonshot",
          model: "kimi-k2"
        })

      # step A errors, falls back to step B — one served request each
      DodoRouter.LogsFixtures.log_fixture(router, %{
        status: "fallback",
        attempted_steps: [
          %{"step_id" => step_a.id, "status" => "error"},
          %{"step_id" => step_b.id, "status" => "success"}
        ]
      })

      # step A alone serves this one cleanly
      DodoRouter.LogsFixtures.log_fixture(router, %{
        status: "success",
        attempted_steps: [
          %{"step_id" => step_a.id, "status" => "success"}
        ]
      })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ ~s(data-step-id="#{step_a.id}")
      assert html =~ ~s(data-step-share="50%")
      assert html =~ ~s(data-step-errors="1")

      assert html =~ ~s(data-step-id="#{step_b.id}")
      assert html =~ ~s(data-step-share="50%")
    end

    test "a step with no traffic in the window is dimmed, not silently zero", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, unused_step} =
        DodoRouter.Routers.create_routing_step(router, %{
          provider: "zai",
          model: "glm-4.6"
        })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ ~s(data-step-id="#{unused_step.id}")
      assert html =~ "no traffic in 24h"
    end
  end
end
