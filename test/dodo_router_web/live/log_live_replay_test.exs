defmodule DodoRouterWeb.LogLiveReplayTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.Logs
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    source =
      LogsFixtures.log_fixture(router, %{
        final_provider: "test_provider",
        final_model: "original-model",
        latency_ms: 1000,
        request_body:
          Jason.encode!(%{
            "model" => "original-model",
            "stream" => true,
            "messages" => [%{"role" => "user", "content" => "hi"}]
          }),
        response_body:
          Jason.encode!(%{
            "choices" => [
              %{"message" => %{"role" => "assistant", "content" => "The quick brown fox"}}
            ]
          })
      })

    %{router: router, provider_key: provider_key, source: source}
  end

  describe "mount" do
    test "renders the target picker and empty state", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      assert has_element?(view, "#replay-form")
      assert has_element?(view, "#replay-empty-state")
      assert has_element?(view, "#run-replay-button")
      assert render(view) =~ "original-model"
    end

    test "blocks replay for truncated sources", %{conn: conn, router: router} do
      truncated =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [%{"role" => "user", "content" => "prompt\n\n... [truncated]"}]
            })
        })

      {:ok, view, _html} = live(conn, ~p"/logs/#{truncated.id}/replay")

      assert has_element?(view, "#replay-blocker")
      refute has_element?(view, "#replay-form")
    end

    test "another user's log is not accessible", %{conn: conn} do
      other_user = AccountsFixtures.user_fixture()
      {other_router, _} = RoutersFixtures.router_fixture(other_user)
      other_log = LogsFixtures.log_fixture(other_router)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/logs/#{other_log.id}/replay")
      end
    end
  end

  describe "running a replay" do
    test "runs, patches to the new replay, and renders the comparison", %{
      conn: conn,
      source: source,
      provider_key: provider_key
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      view
      |> form("#replay-form", replay: %{provider_key_id: provider_key.id, model: "test-model"})
      |> render_submit()

      render_async(view)

      [replay] = Logs.list_replays(source)
      assert_patch(view, ~p"/logs/#{source.id}/replay?replay=#{replay.id}")

      render_async(view)

      assert has_element?(view, "#compare-original")
      assert has_element?(view, "#compare-replay")
      assert has_element?(view, "#delta-strip")
      assert has_element?(view, "#delta-latency_ms")
      assert has_element?(view, "#content-diff")
      assert has_element?(view, "#replay-switcher")

      assert replay.replayed_from_id == source.id
      assert replay.final_model == "test-model"
    end
  end

  describe "reasoning effort" do
    test "offers catalog efforts for a known model", %{conn: conn, source: source} do
      {:ok, _model} =
        DodoRouter.Models.create_model(%{
          provider_slug: "test_provider",
          model_id: "test-model",
          display_name: "Test Model",
          reasoning_efforts: ["low", "high"]
        })

      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      html =
        view
        |> form("#replay-form")
        |> render_change(%{replay: %{model: "test-model"}})

      assert has_element?(view, "#replay-effort")
      assert html =~ ~s(<option value="low")
      assert html =~ ~s(<option value="high")
      refute html =~ ~s(<option value="xhigh")
      assert html =~ "As original"
    end

    test "falls back to the generic effort set for unknown models", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      html =
        view
        |> form("#replay-form")
        |> render_change(%{replay: %{model: "some-custom-model"}})

      assert html =~ ~s(<option value="minimal")
      assert html =~ ~s(<option value="xhigh")
    end

    test "replaying with an effort shows it on the comparison", %{
      conn: conn,
      source: source,
      provider_key: provider_key
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      view
      |> form("#replay-form",
        replay: %{
          provider_key_id: provider_key.id,
          model: "test-model",
          reasoning_effort: "high"
        }
      )
      |> render_submit()

      render_async(view)

      [replay] = Logs.list_replays(source)
      assert_patch(view, ~p"/logs/#{source.id}/replay?replay=#{replay.id}")
      render_async(view)

      assert [step] = replay.attempted_steps
      assert step["reasoning_effort"] == "high"
      assert has_element?(view, "#compare-replay", "high")
    end
  end

  describe "existing replays" do
    setup %{router: router, source: source} do
      response = fn content ->
        Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
        })
      end

      first =
        LogsFixtures.log_fixture(router, %{
          replayed_from_id: source.id,
          final_model: "model-a",
          latency_ms: 500,
          response_body: response.("The quick red fox"),
          inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      second =
        LogsFixtures.log_fixture(router, %{
          replayed_from_id: source.id,
          final_model: "model-b",
          latency_ms: 2000,
          response_body: response.("A slow green turtle")
        })

      %{first: first, second: second}
    end

    test "arriving shows the candidates overview, not a single comparison", %{
      conn: conn,
      source: source
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      assert has_element?(view, "#candidates-table")
      assert has_element?(view, "#candidate-row-original", "original-model")
      assert has_element?(view, "#candidate-row-1", "model-a")
      assert has_element?(view, "#candidate-row-2", "model-b")
      refute has_element?(view, "#compare-replay")
    end

    test "clicking a candidate row opens its comparison", %{
      conn: conn,
      source: source,
      first: first
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay")

      view |> element("#candidate-row-1") |> render_click()
      assert_patch(view, ~p"/logs/#{source.id}/replay?replay=#{first.id}")
      render_async(view)

      assert has_element?(view, "#compare-replay", "model-a")
    end

    test "the All replays link returns to the overview", %{
      conn: conn,
      source: source,
      first: first
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay?replay=#{first.id}")
      render_async(view)

      view |> element("#all-replays-link") |> render_click()
      assert_patch(view, ~p"/logs/#{source.id}/replay")

      assert has_element?(view, "#candidates-table")
      refute has_element?(view, "#compare-replay")
    end

    test "the Replay button on the log page shows the candidate count", %{
      conn: conn,
      source: source
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}")

      assert has_element?(view, "#replay-button", "2")
    end

    test "the logs index shows replay counts on originals", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/logs")

      assert has_element?(view, ~s(#logs-#{source.id} [title="Has 2 replays"]))
    end

    test "?replay= selects a specific replay and switcher patches between them", %{
      conn: conn,
      source: source,
      first: first
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay?replay=#{first.id}")
      render_async(view)

      assert has_element?(view, "#compare-replay", "model-a")

      view |> element("#replay-chip-2") |> render_click()
      render_async(view)

      assert has_element?(view, "#compare-replay", "model-b")
    end

    test "diff view renders word-level segments", %{conn: conn, source: source, first: first} do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay?replay=#{first.id}")
      html = render_async(view)

      assert has_element?(view, "#content-diff")
      assert html =~ "brown"
      assert html =~ "red"
      assert has_element?(view, "#content-diff del")
      assert has_element?(view, "#content-diff ins")
    end

    test "raw view shows both response bodies", %{conn: conn, source: source, second: second} do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}/replay?replay=#{second.id}")
      render_async(view)

      view |> element("#diff-view-raw") |> render_click()

      assert has_element?(view, "#compare-raw-pane")
      assert render(view) =~ "quick brown fox"
    end
  end

  describe "replay from a specific message" do
    setup %{router: router} do
      multi_turn =
        LogsFixtures.log_fixture(router, %{
          final_provider: "test_provider",
          final_model: "original-model",
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [
                %{"role" => "user", "content" => "first question"},
                %{"role" => "assistant", "content" => "the failing crud answer"},
                %{"role" => "user", "content" => "second question"}
              ]
            }),
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{"message" => %{"role" => "assistant", "content" => "the final answer"}}
              ]
            })
        })

      %{multi_turn: multi_turn}
    end

    test "user messages on the log page offer replay-from-here", %{
      conn: conn,
      multi_turn: multi_turn
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{multi_turn.id}")

      assert has_element?(view, ~s(a[href="/logs/#{multi_turn.id}/replay?from=0"]))
      assert has_element?(view, ~s(a[href="/logs/#{multi_turn.id}/replay?from=2"]))
      refute has_element?(view, ~s(a[href="/logs/#{multi_turn.id}/replay?from=1"]))
    end

    test "the hub banners the cut point and the partial replay compares against the exchange answer",
         %{conn: conn, multi_turn: multi_turn, provider_key: provider_key} do
      {:ok, view, _html} = live(conn, ~p"/logs/#{multi_turn.id}/replay?from=0")

      assert has_element?(view, "#replay-from-banner", "first question")

      view
      |> form("#replay-form", replay: %{provider_key_id: provider_key.id, model: "test-model"})
      |> render_submit()

      render_async(view)

      [replay] = Logs.list_replays(multi_turn)
      assert_patch(view, ~p"/logs/#{multi_turn.id}/replay?replay=#{replay.id}")
      html = render_async(view)

      assert Jason.decode!(replay.request_body)["messages"] ==
               [%{"role" => "user", "content" => "first question"}]

      assert has_element?(view, "#partial-replay-banner")
      refute has_element?(view, "#delta-strip")
      # diff runs against the original answer at that exchange, not the final response
      assert html =~ "crud"
      refute has_element?(view, "#content-diff", "the final answer")
    end

    test "the candidates table labels partial replays with their cut point and message", %{
      conn: conn,
      multi_turn: multi_turn
    } do
      _partial =
        LogsFixtures.log_fixture(router_of(multi_turn), %{
          replayed_from_id: multi_turn.id,
          final_model: "model-partial",
          request_body:
            Jason.encode!(%{
              "messages" => [%{"role" => "user", "content" => "first question"}]
            })
        })

      {:ok, view, _html} = live(conn, ~p"/logs/#{multi_turn.id}/replay")

      assert has_element?(view, "#candidate-row-1", "from #1")
      assert has_element?(view, ~s(#candidate-row-1 [title*="first question"]))
    end

    test "the partial comparison shows which message anchored the replay", %{
      conn: conn,
      multi_turn: multi_turn
    } do
      partial =
        LogsFixtures.log_fixture(router_of(multi_turn), %{
          replayed_from_id: multi_turn.id,
          final_model: "model-partial",
          request_body:
            Jason.encode!(%{
              "messages" => [%{"role" => "user", "content" => "first question"}]
            })
        })

      {:ok, view, _html} = live(conn, ~p"/logs/#{multi_turn.id}/replay?replay=#{partial.id}")
      render_async(view)

      assert has_element?(view, "#partial-replay-banner", "first question")
    end

    test "viewing a partial replay adopts its cut point for the next run", %{
      conn: conn,
      multi_turn: multi_turn,
      provider_key: provider_key
    } do
      partial =
        LogsFixtures.log_fixture(router_of(multi_turn), %{
          replayed_from_id: multi_turn.id,
          final_model: "model-partial",
          request_body:
            Jason.encode!(%{
              "messages" => [%{"role" => "user", "content" => "first question"}]
            })
        })

      {:ok, view, _html} = live(conn, ~p"/logs/#{multi_turn.id}/replay?replay=#{partial.id}")
      render_async(view)

      # the picker shows the adopted cut point
      assert has_element?(view, "#replay-from-banner", "first question")

      # running with another model repeats the same exchange
      view
      |> form("#replay-form", replay: %{provider_key_id: provider_key.id, model: "test-model"})
      |> render_submit()

      render_async(view)

      replays = Logs.list_replays(multi_turn)
      new_replay = Enum.find(replays, &(&1.final_model == "test-model"))

      assert Jason.decode!(new_replay.request_body)["messages"] ==
               [%{"role" => "user", "content" => "first question"}]
    end
  end

  describe "thread section" do
    setup %{router: router} do
      multi_turn =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "first question"},
                %{"role" => "assistant", "content" => "the failing crud answer"},
                %{"role" => "user", "content" => "second question"}
              ]
            })
        })

      %{multi_turn: multi_turn}
    end

    test "the hub shows the thread with from-here pickers on user messages", %{
      conn: conn,
      multi_turn: multi_turn
    } do
      {:ok, view, _html} = live(conn, ~p"/logs/#{multi_turn.id}/replay")

      assert has_element?(view, "#thread-section", "first question")
      assert has_element?(view, "#thread-section", "second question")
      assert has_element?(view, "#thread-from-0")
      assert has_element?(view, "#thread-from-2")
      refute has_element?(view, "#thread-from-1")

      view |> element("#thread-from-0") |> render_click()
      assert_patch(view, ~p"/logs/#{multi_turn.id}/replay?from=0")
      assert has_element?(view, "#replay-from-banner", "first question")
    end

    test "a truncation-blocked thread still offers partial replays", %{
      conn: conn,
      router: router
    } do
      blocked_root =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "clean question"},
                %{"role" => "assistant", "content" => "big answer\n\n... [truncated]"},
                %{"role" => "user", "content" => "follow-up"}
              ]
            })
        })

      partial =
        LogsFixtures.log_fixture(router, %{
          replayed_from_id: blocked_root.id,
          final_model: "model-partial",
          request_body:
            Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "clean question"}]})
        })

      # whole-thread mode: blocked, but the thread is browsable
      {:ok, view, _html} = live(conn, ~p"/logs/#{blocked_root.id}/replay")
      assert has_element?(view, "#replay-blocker")
      refute has_element?(view, "#replay-form")
      assert has_element?(view, "#thread-section")

      # picking a clean cut point unblocks the picker
      view |> element("#thread-from-0") |> render_click()
      assert has_element?(view, "#replay-form")
      refute has_element?(view, "#replay-blocker")

      # viewing the existing partial adopts its cut and offers the picker too
      {:ok, view, _html} =
        live(conn, ~p"/logs/#{blocked_root.id}/replay?replay=#{partial.id}")

      render_async(view)
      assert has_element?(view, "#replay-form")
      assert has_element?(view, "#replay-from-banner", "clean question")
      refute has_element?(view, "#replay-blocker")
    end
  end

  defp router_of(log), do: %DodoRouter.Routers.Router{id: log.router_id}

  describe "root anchoring" do
    test "visiting a replay's page redirects to the root hub with it selected", %{
      conn: conn,
      router: router,
      source: source
    } do
      replay_log = LogsFixtures.log_fixture(router, %{replayed_from_id: source.id})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/logs/#{replay_log.id}/replay")

      assert to == "/logs/#{source.id}/replay?replay=#{replay_log.id}"
    end
  end

  describe "entry points" do
    test "log detail page links to the replay page", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/logs/#{source.id}")

      assert has_element?(view, "#replay-button")
      refute has_element?(view, "#replay-of-link")
    end

    test "a replay log links back to its original comparison and offers no Replay action", %{
      conn: conn,
      router: router,
      source: source
    } do
      replay = LogsFixtures.log_fixture(router, %{replayed_from_id: source.id})

      {:ok, view, _html} = live(conn, ~p"/logs/#{replay.id}")

      assert has_element?(view, "#replay-of-link")
      refute has_element?(view, "#replay-button")
    end

    test "logs index badges replay rows", %{conn: conn, router: router, source: source} do
      replay = LogsFixtures.log_fixture(router, %{replayed_from_id: source.id})

      {:ok, view, _html} = live(conn, ~p"/logs")

      assert has_element?(view, "#logs-#{replay.id}", "replay")
      refute has_element?(view, "#logs-#{source.id} .badge", "replay")
    end
  end
end
