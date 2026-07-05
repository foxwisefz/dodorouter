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
      # Connect is expanded by default on a router with no traffic yet
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "curl"
      assert html =~ router.slug
    end

    test "fresh router shows the getting-started checklist and open Connect panel", %{
      conn: conn,
      router: router
    } do
      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}")

      assert has_element?(live, "#setup-checklist")
      assert html =~ "0/4 done"
      # Connect must be expanded for a router with no traffic — the first
      # code snippet is the next thing a new user needs.
      assert html =~ "curl"
    end

    test "checklist tracks progress and disappears once the router is live", %{
      conn: conn,
      router: router,
      user: user
    } do
      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard"
        })

      {:ok, step} =
        DodoRouter.Routers.create_routing_step(router, %{
          "provider" => "zai",
          "model" => "glm-4.7"
        })

      {:ok, _step} = DodoRouter.Routers.update_routing_step(step, %{provider_key_id: key.id})

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}")
      assert html =~ "3/4 done"

      LogsFixtures.log_fixture(router, %{status: "success"})

      # The already-open page hears the new log over PubSub and completes live
      refute render(live) =~ "setup-checklist"

      {:ok, live2, _html} = live(conn, ~p"/routers/#{router.id}")
      refute has_element?(live2, "#setup-checklist")
    end

    test "add-step modal preselects the provider the user has a key for", %{
      conn: conn,
      router: router,
      user: user
    } do
      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"provider_slug" => "moonshot"})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/routing")

      assert html =~ ~r/<option[^>]*value="moonshot"[^>]*selected/
    end

    test "add-step modal warns when the user has no keys for the provider", %{
      conn: conn,
      router: router
    } do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing")

      # Default provider is zai and this user has no provider keys at all
      assert has_element?(live, "#step-provider-no-keys")
      assert render(live) =~ "/providers"
    end

    test "add-step modal shows no key warning when a matching key exists", %{
      conn: conn,
      router: router,
      user: user
    } do
      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"provider_slug" => "zai_standard"})

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing")

      refute has_element?(live, "#step-provider-no-keys")
    end

    test "shows recent logs section", %{conn: conn, router: router} do
      LogsFixtures.log_fixture(router, %{final_provider: "test-provider"})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "test-provider"
    end

    test "can switch code language and format", %{conn: conn, router: router} do
      # Connect starts expanded for a router with no traffic
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}")

      # Switch to Python
      html =
        live
        |> element("button[phx-click=\"set_code_language\"][phx-value-language=\"python\"]")
        |> render_click()

      assert html =~ "openai" or html =~ "python"

      # Switch to Anthropic format
      html =
        live
        |> element("button[phx-click=\"set_api_format\"][phx-value-format=\"anthropic\"]")
        |> render_click()

      assert html =~ "anthropic" or html =~ "messages"
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

    test "model select lists known models", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/routing")

      assert html =~ "Reasoning Effort"
      assert html =~ "Temperature"
      assert html =~ "Max Tokens"
    end

    test "can add a step with a known model", %{conn: conn, router: router} do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing")

      live
      |> form("#routing-modal form", %{
        "step" => %{
          "provider" => "zai",
          "model" => "glm-5",
          "reasoning_effort" => "high"
        }
      })
      |> render_submit()

      steps = DodoRouter.Routers.list_routing_steps(router)
      assert length(steps) == 1
      step = hd(steps)
      assert step.provider == "zai"
      assert step.model == "glm-5"
      assert step.reasoning_effort == "high"
    end

    test "effort options come from synced model data when available", %{
      conn: conn,
      router: router
    } do
      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "zai",
          model_id: "glm-5",
          display_name: "GLM 5",
          reasoning_efforts: ["high", "max"]
        })

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing")

      html =
        live
        |> form("#routing-modal form", %{"step" => %{"provider" => "zai", "model" => "glm-5"}})
        |> render_change()

      assert html =~ "Levels this model supports"
      # Model-specific list replaces the canonical one
      refute html =~ "Minimal"
    end

    test "can edit a step's reasoning effort", %{conn: conn, router: router} do
      {:ok, step} =
        DodoRouter.Routers.create_routing_step(router, %{
          "provider" => "zai",
          "model" => "glm-5",
          "reasoning_effort" => "high"
        })

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}/routing/#{step.id}/edit")

      assert html =~ "Edit Routing Step"
      assert html =~ "Save Changes"

      live
      |> form("#routing-modal form", %{
        "step" => %{
          "provider" => "zai",
          "model" => "glm-5",
          "reasoning_effort" => "medium"
        }
      })
      |> render_submit()

      updated = DodoRouter.Routers.get_routing_step!(router, step.id)
      assert updated.reasoning_effort == "medium"
      assert updated.model == "glm-5"
      assert updated.position == step.position
    end

    test "editing can clear optional overrides", %{conn: conn, router: router} do
      {:ok, step} =
        DodoRouter.Routers.create_routing_step(router, %{
          "provider" => "zai",
          "model" => "glm-5",
          "reasoning_effort" => "high",
          "temperature" => 0.7
        })

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing/#{step.id}/edit")

      live
      |> form("#routing-modal form", %{
        "step" => %{
          "provider" => "zai",
          "model" => "glm-5",
          "reasoning_effort" => "",
          "temperature" => ""
        }
      })
      |> render_submit()

      updated = DodoRouter.Routers.get_routing_step!(router, step.id)
      assert updated.reasoning_effort == nil
      assert updated.temperature == nil
    end

    test "cannot edit a step belonging to another user's router", %{conn: conn, router: router} do
      {other_router, _} = DodoRouter.RoutersFixtures.router_fixture()

      {:ok, other_step} =
        DodoRouter.Routers.create_routing_step(other_router, %{
          "provider" => "zai",
          "model" => "glm-5"
        })

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/routers/#{router.id}/routing/#{other_step.id}/edit")
      end
    end

    test "can add a step with a custom model", %{conn: conn, router: router} do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing")

      live
      |> form("#routing-modal form", %{"step" => %{"model" => "__custom__"}})
      |> render_change()

      live
      |> form("#routing-modal form", %{
        "step" => %{
          "model" => "custom-model",
          "reasoning_effort" => "xhigh"
        }
      })
      |> render_submit()

      step =
        DodoRouter.Routers.list_routing_steps(router)
        |> hd()

      assert step.provider == "zai"
      assert step.model == "custom-model"
      assert step.reasoning_effort == "xhigh"
    end
  end
end
