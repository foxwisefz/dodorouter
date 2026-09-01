defmodule DodoRouterWeb.RouterShowLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.LogsFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, api_key} = RoutersFixtures.router_fixture(user)

    # The step form offers what the catalog holds — the adapters no longer
    # carry hardcoded model lists, so a model has to exist to be selectable.
    {:ok, _} =
      DodoRouter.Models.upsert_model(%{
        provider_slug: "zai",
        model_id: "glm-5",
        display_name: "GLM-5",
        last_seen_at: DateTime.utc_now()
      })

    %{router: router, api_key: api_key}
  end

  describe "Show" do
    test "a request already in flight when the page mounts shows as a pending row", %{
      conn: conn,
      router: router
    } do
      request_id = Ecto.UUID.generate()

      pending =
        DodoRouter.Logs.PendingLog.build(
          router,
          request_id,
          %{provider: "anthropic", model: "claude-opus-4-8"},
          false
        )

      DodoRouter.Activity.request_started(router.id, request_id, pending)
      wait_until(fn -> DodoRouter.Activity.list_pending([router.id]) != [] end)

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}")

      # The request started before this LiveView existed, so no :log_pending
      # broadcast reached it and no request_logs row exists yet — the row must
      # come from Activity's stored pending payload.
      assert has_element?(live, "#recent_logs-#{request_id}")
      assert html =~ "claude-opus-4-8"

      # A fallback firing after mount must still move the merged row to the
      # backup step, so it needs to be tracked like a broadcast-delivered one.
      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router.id}:logs",
        {:log_pending_update,
         %{
           router_id: router.id,
           request_id: request_id,
           provider: "moonshot",
           model: "kimi-k2.6",
           plan_type: "coding",
           step_index: 1,
           timestamp: DateTime.utc_now()
         }}
      )

      html = render(live)
      assert html =~ "kimi-k2.6"
      refute html =~ "claude-opus-4-8"

      DodoRouter.Activity.request_completed(router.id, request_id)
    end

    test "a pending row moves to the backup step when a fallback fires", %{
      conn: conn,
      router: router
    } do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}")

      request_id = Ecto.UUID.generate()

      # The same payload the proxy broadcasts (and stores in Activity)
      pending =
        DodoRouter.Logs.PendingLog.build(
          router,
          request_id,
          %{provider: "anthropic", model: "claude-opus-4-8"},
          false
        )

      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router.id}:logs",
        {:log_pending, pending}
      )

      assert render(live) =~ "claude-opus-4-8"

      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router.id}:logs",
        {:log_pending_update,
         %{
           router_id: router.id,
           request_id: request_id,
           provider: "moonshot",
           model: "kimi-k2.6",
           plan_type: "coding",
           step_index: 1,
           timestamp: DateTime.utc_now()
         }}
      )

      # The row must name the step actually serving, not the provider that
      # already failed.
      html = render(live)
      assert html =~ "kimi-k2.6"
      refute html =~ "claude-opus-4-8"
    end

    test "shows router details", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ router.name
      assert html =~ router.slug
    end

    test "shows API usage snippet with a copy button", %{conn: conn, router: router} do
      # Connect is expanded by default on a router with no traffic yet
      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "curl"
      assert html =~ router.slug
      assert has_element?(live, "#copy-snippet[phx-hook=CopyButton][data-copy]")
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

    test "add-step provider list mirrors the Providers page", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/routing")

      # Key-slug granularity, including subscription keys…
      assert html =~ ~s(value="anthropic_oauth")
      assert html =~ "Claude subscription"
      assert html =~ ~s(value="zai_coding")
      # …and no internal test provider
      refute html =~ ~s(value="test_provider")
    end

    test "model select includes models synced from models.dev", %{conn: conn, router: router} do
      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "zai",
          model_id: "glm-6-fresh-from-sync",
          display_name: "GLM 6"
        })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/routing")

      assert html =~ "glm-6-fresh-from-sync"
    end

    test "adding a step auto-assigns the matching key", %{conn: conn, router: router, user: user} do
      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard"
        })

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/routing")

      live
      |> form("#routing-modal form", %{"step" => %{"model" => "glm-5"}})
      |> render_submit()

      [step] = DodoRouter.Routers.list_routing_steps(router)
      assert step.provider == "zai"
      assert step.plan_type == "standard"
      assert step.provider_key_id == key.id
    end

    test "an unhealthy assigned key shows a warning on the chain", %{
      conn: conn,
      router: router,
      user: user
    } do
      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard"
        })

      {:ok, step} =
        DodoRouter.Routers.create_routing_step(router, %{"provider" => "zai", "model" => "glm-5"})

      {:ok, _} = DodoRouter.Routers.update_routing_step(step, %{provider_key_id: key.id})
      DodoRouter.Providers.apply_health(key.id, :auth_invalid, "invalid_api_key")

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      assert html =~ "failing authentication"
      # The key picker now labels health the same way everywhere it offers
      # a provider key, rather than with wording unique to this page.
      assert html =~ "not authenticating"
    end

    test "chain key selects offer subscription keys of the same adapter", %{
      conn: conn,
      router: router,
      user: user
    } do
      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
        "provider_slug" => "anthropic_oauth",
        "label" => "Claude Max"
      })

      {:ok, _step} =
        DodoRouter.Routers.create_routing_step(router, %{
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-20250514"
        })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}")

      # The oauth key must be selectable even though the step's derived
      # key slug would be plain "anthropic"
      assert html =~ "Claude Max"
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
      # Upsert: the shared setup already seeds this model so the step form
      # has something to offer at all.
      {:ok, _} =
        DodoRouter.Models.upsert_model(%{
          provider_slug: "zai",
          model_id: "glm-5",
          display_name: "GLM 5",
          reasoning_efforts: ["high", "max"],
          last_seen_at: DateTime.utc_now()
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

  # Activity casts are async, so registration must be confirmed before mounting.
  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        wait_until(fun, deadline - System.monotonic_time(:millisecond))
    end
  end
end
