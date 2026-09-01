defmodule DodoRouterWeb.LogLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.{Evaluations, Logs, RoutersFixtures}
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists logs for all routers", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router, %{final_provider: "test-provider"})

      {:ok, _live, html} = live(conn, ~p"/logs")

      assert html =~ "Request Logs"
      assert html =~ log.final_provider
    end

    test "column headers group the failure-reading path (time, status, provider, latency) before secondary context",
         %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/logs")

      thead = live |> element("thead") |> render()

      headers = [
        "Time",
        "Status",
        "Provider / Model",
        "Latency",
        "Router",
        "Type",
        "Tokens",
        "Message"
      ]

      positions =
        Enum.map(headers, fn header ->
          {pos, _} = :binary.match(thead, header)
          pos
        end)

      assert positions == Enum.sort(positions),
             "expected column headers in order #{inspect(headers)}, got positions #{inspect(positions)}"
    end

    test "shows plain count when under the limit", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)
      LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/logs")

      html = render(live)
      assert html =~ ~s(id="logs-count")
      assert html =~ "2 requests"
      refute html =~ "showing"
    end

    test "shows 'showing X of N' when results are truncated by the limit", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      for _ <- 1..101 do
        LogsFixtures.log_fixture(router)
      end

      {:ok, live, _html} = live(conn, ~p"/logs")

      html = render(live)
      assert html =~ ~s(id="logs-count")
      assert html =~ "showing 100 of 101 requests"
    end

    test "colors latency against the router's own p95 baseline", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      for _ <- 1..20 do
        LogsFixtures.log_fixture(router, %{latency_ms: 100})
      end

      LogsFixtures.log_fixture(router, %{latency_ms: 10_000})

      {:ok, live, _html} = live(conn, ~p"/logs?router_id=#{router.id}")

      html = render(live)
      assert html =~ ~s(data-latency-band="slow")
      assert html |> String.split(~s(data-latency-band="slow")) |> length() == 2
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

    test "failures filter shows only error/fallback rows and the breakdown banner", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      LogsFixtures.log_fixture(router, %{
        status: "error",
        final_provider: "flaky-provider",
        final_model: "flaky-model"
      })

      LogsFixtures.log_fixture(router, %{
        status: "fallback",
        final_provider: "backup-provider",
        final_model: "backup-model"
      })

      LogsFixtures.log_fixture(router, %{status: "success", final_provider: "ok-provider"})

      {:ok, live, html} =
        live(conn, ~p"/logs?router_id=#{router.id}&failures=true")

      assert html =~ "flaky-provider"
      assert html =~ "backup-provider"
      refute html =~ "ok-provider"

      assert has_element?(live, "#failure-breakdown")
      assert html =~ "last 24h"
      assert html =~ "flaky-provider/flaky-model"
      assert html =~ "backup-provider/backup-model"
    end

    test "a :log_created success does not appear while in failures mode", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/logs?router_id=#{router.id}&failures=true")

      # broadcasts to subscribers, mirroring how a real request completes
      {:ok, _log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          final_provider: "should-not-appear",
          final_model: "test-model"
        })

      html = render(live)
      refute html =~ "should-not-appear"

      {:ok, _log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "error",
          final_provider: "should-appear",
          final_model: "test-model"
        })

      html = render(live)
      assert html =~ "should-appear"
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

  describe "Create evaluation entry point" do
    test "links a request to the evaluation builder", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "#create-eval-button[href='/logs/#{log.id}/evals/new']")
    end

    test "links a request to evaluations created from it", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      provider_key = ProvidersFixtures.provider_key_fixture(user)
      log = LogsFixtures.log_fixture(router)

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Answer quality",
          criteria: "Be correct",
          judge_model: "test-model",
          judge_provider_key_id: provider_key.id,
          candidate_targets: [
            %{
              "provider_key_id" => provider_key.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}")

      assert has_element?(
               live,
               "#log-evaluations a[href='/evals/#{evaluation.id}']",
               "Answer quality"
             )
    end
  end

  describe "Show" do
    test "left rail groups boxes by task, not by data source", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          session_id: "task-grouping-session",
          attempted_steps: [
            %{"provider" => "test_provider", "status" => "success", "latency_ms" => 100}
          ]
        })

      {:ok, live, html} = live(conn, ~p"/logs/#{log.request_id}")

      # all preserved information is present, just regrouped
      assert has_element?(live, "[data-group='what-happened']")
      assert has_element?(live, "[data-group='what-it-cost']")
      assert has_element?(live, "[data-group='where-it-came-from']")

      # "what happened" carries status, model/provider and the routing chain
      assert has_element?(live, "[data-group='what-happened']", "Status")
      assert has_element?(live, "[data-group='what-happened']", "Model")
      assert has_element?(live, "[data-group='what-happened']", "Routing")

      # "what it cost" carries usage/cache/cost
      assert has_element?(live, "[data-group='what-it-cost']", "Cost")

      # "where it came from" carries the session
      assert has_element?(live, "[data-group='where-it-came-from']", "task-grouping-session")

      assert html =~ "Left sidebar"
    end

    test "subscription-covered requests say plan instead of $0.0000", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          estimated_cost_usd: Decimal.new(0),
          attempted_steps: [
            %{
              "provider" => "zai",
              "provider_key_slug" => "zai_coding",
              "model" => "glm-4.7",
              "status" => "success",
              "latency_ms" => 100
            }
          ]
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "included in plan"
      refute html =~ "$0.0000"

      # a zero-cost API-key request keeps the dollar figure
      api_log =
        LogsFixtures.log_fixture(router, %{
          estimated_cost_usd: Decimal.new(0),
          attempted_steps: [
            %{
              "provider" => "openai",
              "provider_key_slug" => "openai",
              "model" => "gpt-4o",
              "status" => "success",
              "latency_ms" => 100
            }
          ]
        })

      {:ok, _live, html2} = live(conn, ~p"/logs/#{api_log.request_id}")
      assert html2 =~ "$0.0000"
    end

    test "plan-covered requests show what they would cost at API rates",
         %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      plan_step = %{
        "provider" => "zai",
        "provider_key_slug" => "zai_coding",
        "model" => "glm-4.7",
        "status" => "success",
        "latency_ms" => 100
      }

      log =
        LogsFixtures.log_fixture(router, %{
          estimated_cost_usd: Decimal.new(0),
          list_cost_usd: Decimal.new("0.0123"),
          attempted_steps: [plan_step]
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "included in plan"
      assert html =~ "~$0.0123 at API rates"

      # Legacy plan-covered logs without a captured list cost stay unchanged.
      legacy_log =
        LogsFixtures.log_fixture(router, %{
          estimated_cost_usd: Decimal.new(0),
          attempted_steps: [plan_step]
        })

      {:ok, _live, legacy_html} = live(conn, ~p"/logs/#{legacy_log.request_id}")

      assert legacy_html =~ "included in plan"
      refute legacy_html =~ "at API rates"
    end

    test "shows the requested model when the router served a different one", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          final_model: "glm-4.7",
          final_provider: "zai",
          request_body:
            Jason.encode!(%{
              "model" => "claude-fable-5",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            })
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "requested"
      assert html =~ "claude-fable-5"

      # same model requested and served -> no redundant line
      same_log =
        LogsFixtures.log_fixture(router, %{
          final_model: "glm-4.7",
          request_body:
            Jason.encode!(%{
              "model" => "glm-4.7",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            })
        })

      {:ok, live2, _} = live(conn, ~p"/logs/#{same_log.request_id}")
      refute render(live2) =~ "requested"
    end

    test "links to the session the request belongs to", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_with_session(router, "checkout-flow")

      {:ok, live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "checkout-flow"

      assert has_element?(
               live,
               ~s(a[href="/routers/#{router.id}/sessions/checkout-flow"])
             )
    end

    test "timing rows only appear when they add information", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      # upload took 0ms and wait therefore equals TTFB: neither row helps
      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 7000,
          ttfb_ms: 2600,
          upload_ms: 0
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "TTFB"
      refute html =~ "Upload"
      refute html =~ "Wait"

      # a real upload keeps both rows
      slow_upload =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 7000,
          ttfb_ms: 2600,
          upload_ms: 400
        })

      {:ok, _live, html2} = live(conn, ~p"/logs/#{slow_upload.request_id}")
      assert html2 =~ "Upload"
      assert html2 =~ "Wait"
    end

    test "timing renders as a single proportional bar with numbers behind a details toggle", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 7000,
          attempted_steps: [%{"latency_ms" => 6800}],
          ttfb_ms: 2600,
          upload_ms: 400,
          provider_processing_ms: 1800
        })

      {:ok, live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "#timing-bar")
      assert has_element?(live, "[data-timing-segment='upload']")
      assert has_element?(live, "[data-timing-segment='wait']")
      assert has_element?(live, "[data-timing-segment='processing']")
      assert has_element?(live, "[data-timing-segment='overhead']")

      # numbers still available, behind an expand rather than always stacked
      assert html =~ "<details"
      assert html =~ "Breakdown"
      assert html =~ "Provider"
      assert html =~ "Overhead"
    end

    test "timing bar renders with only unattributed/overhead when finer fields are missing (old rows)",
         %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 5000,
          ttfb_ms: nil,
          upload_ms: nil,
          provider_processing_ms: nil
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "#timing-bar")
      refute has_element?(live, "[data-timing-segment='upload']")
      refute has_element?(live, "[data-timing-segment='wait']")
      refute has_element?(live, "[data-timing-segment='processing']")
    end

    test "overhead and cost carry a router-median comparison basis", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      # establish a router baseline: several requests at a known latency/cost
      for _ <- 1..5 do
        LogsFixtures.log_fixture(router, %{
          latency_ms: 1000,
          estimated_cost_usd: Decimal.new("0.0200")
        })
      end

      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 7000,
          attempted_steps: [%{"latency_ms" => 6800}],
          estimated_cost_usd: Decimal.new("0.0412")
        })

      {:ok, live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "#overhead-baseline")
      assert has_element?(live, "#cost-baseline")
      assert html =~ "router median"
    end

    test "omits the baseline rather than fabricate one when the router has no recent traffic", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 3000,
          estimated_cost_usd: Decimal.new("0.0100")
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      # this log IS the router's only traffic — its own p50 equals itself,
      # so no meaningful comparison basis exists and none should be fabricated
      refute has_element?(live, "#overhead-baseline")
      refute has_element?(live, "#cost-baseline")
    end

    test "marks the dominant hop in a multi-attempt routing chain", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 5000,
          attempted_steps: [
            %{"provider" => "provider_a", "status" => "error", "latency_ms" => 4500},
            %{"provider" => "provider_b", "status" => "success", "latency_ms" => 500}
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "[data-hop-slow='true']")
      refute has_element?(live, "[data-hop-slow='true']", "provider_b")
    end

    test "does not mark any hop when latency is evenly spread", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          latency_ms: 1000,
          attempted_steps: [
            %{"provider" => "provider_a", "status" => "error", "latency_ms" => 500},
            %{"provider" => "provider_b", "status" => "success", "latency_ms" => 500}
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      refute has_element?(live, "[data-hop-slow='true']")
    end

    test "model reasoning is viewable but collapsed", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "2+2?"}]}),
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{
                  "finish_reason" => "stop",
                  "message" => %{
                    "role" => "assistant",
                    "content" => "4",
                    "reasoning_content" => "The user wants simple arithmetic. 2+2 equals 4."
                  }
                }
              ]
            })
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "Reasoning"
      assert html =~ "simple arithmetic"
      # collapsed by default: the <details> tag itself carries no open attr
      assert html =~ ~r/<details[^>]*reasoning-block/
      refute html =~ ~r/<details[^>]*reasoning-block[^>]*\sopen[\s>]/
    end

    test "final response sections start expanded, history stays collapsed", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "## Earlier heading\n\nold context"},
                %{"role" => "user", "content" => "write the report"}
              ]
            }),
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{
                  "finish_reason" => "stop",
                  "message" => %{
                    "role" => "assistant",
                    "content" => "## Findings\n\nAll good.\n\n## Next steps\n\nShip it."
                  }
                }
              ]
            })
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      # the response's sections are open; the history message's are not
      assert html =~ ~r/<details class="md-section" open/
      assert html =~ ~r/<details class="md-section">/
    end

    test "system preamble folds into a single row so the dialogue leads", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "system", "content" => String.duplicate("rules ", 200)},
                %{"role" => "system", "content" => "more rules"},
                %{"role" => "user", "content" => "the actual question"}
              ]
            }),
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{"message" => %{"role" => "assistant", "content" => "the actual answer"}}
              ]
            })
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "System prompt"
      assert html =~ "2 messages"
      # collapsed by default
      assert html =~ ~r/<details[^>]*system-block/
      refute html =~ ~r/<details[^>]*system-block[^>]*\sopen[\s>]/
      assert html =~ "the actual question"
      assert html =~ "the actual answer"
    end

    test "detail page renders no duplicate element ids", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "system", "content" => "be terse"},
                %{"role" => "user", "content" => "hello"},
                %{"role" => "assistant", "content" => "hi"},
                %{"role" => "user", "content" => "more"}
              ]
            }),
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{
                  "finish_reason" => "stop",
                  "message" => %{"role" => "assistant", "content" => "sure"}
                }
              ]
            })
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
      dupes = ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
      assert dupes == [], "duplicate element ids: #{inspect(dupes)}"
    end

    test "a clean request says so instead of rendering nothing", %{conn: conn, user: user} do
      # "We changed nothing" is the claim the whole fidelity stack exists to
      # make. Silence is the wrong way to say it — an empty panel reads as a
      # missing feature, not as a guarantee kept.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          fidelity_changes: [],
          final_provider: "anthropic"
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "Passed through unchanged"
      assert html =~ "anthropic"
      refute html =~ "What the proxy changed"
    end

    test "a request that lost something says so and points at the hop", %{conn: conn, user: user} do
      # The conversation view states that something was changed; the change
      # itself lives on the trace, under the hop that made it, because that is
      # the only place it can sit next to its own evidence.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: [
            %{"position" => 0, "provider" => "openai", "model" => "gpt-4o", "status" => "success"}
          ],
          fidelity_changes: [
            %{
              "channel" => "request_body",
              "name" => "context_management",
              "action" => "dropped",
              "reason" => "unsupported_by_format_conversion",
              "provider" => "openai",
              "step" => 0
            }
          ]
        })

      {:ok, live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "What the proxy changed"
      refute html =~ "Passed through unchanged"
      assert has_element?(live, "#fidelity-summary")

      html = live |> element("#fidelity-summary") |> render_click()
      assert html =~ "context_management"
    end

    test "a truncated response is called out even when the request succeeded", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          status: "success",
          request_body: Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]}),
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{
                  "finish_reason" => "length",
                  "message" => %{"role" => "assistant", "content" => "Call me Ish"}
                }
              ]
            })
        })

      {:ok, live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "#truncation-notice")
      assert html =~ "max_tokens"

      # and a normal stop response shows no such warning
      ok_log =
        LogsFixtures.log_fixture(router, %{
          response_body:
            Jason.encode!(%{
              "choices" => [
                %{
                  "finish_reason" => "stop",
                  "message" => %{"role" => "assistant", "content" => "done"}
                }
              ]
            })
        })

      {:ok, live2, _} = live(conn, ~p"/logs/#{ok_log.request_id}")
      refute has_element?(live2, "#truncation-notice")
    end

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
      # OpenAI-family usage: prompt_tokens (500) already includes the 400
      # cache reads, so the hit rate is 400/500 and new input is 100.
      assert html =~ "(80%)"
      # new (uncached) input and output are separated so the cached figure
      # can't dwarf an ambiguous "Tokens" total
      assert html =~ "Input (new)"
      assert html =~ "Output"
    end

    test "Anthropic-style cache tokens don't blow past 100%", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      # Anthropic reports input_tokens as newly-billed input only, so
      # 38_356 cache reads over 260 billed tokens rendered as "14752%".
      log =
        LogsFixtures.log_fixture(router, %{
          final_provider: "anthropic",
          final_model: "claude-opus-4-7",
          prompt_tokens: 260,
          completion_tokens: 1175,
          total_tokens: 1435,
          cache_read_tokens: 38_356,
          cache_write_tokens: 0
        })

      {:ok, _live, html} = live(conn, ~p"/logs/#{log.request_id}")

      assert html =~ "(99%)"
      refute html =~ "14752%"
    end

    test "renders per-step response body in the trace", %{conn: conn, user: user} do
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
        |> element("[role=tab][phx-value-tab=trace]")
        |> render_click()

      assert has_element?(live, "#trace-response-body-1")
      assert html =~ "converted"
      assert html =~ "hello"
    end

    test "renders per-step response headers in the trace", %{conn: conn, user: user} do
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
        |> element("[role=tab][phx-value-tab=trace]")
        |> render_click()

      assert has_element?(live, "#trace-response-headers-1")
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
        |> element("[role=tab][phx-value-tab=trace]")
        |> render_click()

      assert has_element?(live, "#trace-error-body-0")
      assert html =~ "Error response"
      assert html =~ "rate limited"
      assert has_element?(live, "#trace-response-body-1")
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
        |> element("[role=tab][phx-value-tab=trace]")
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

  describe "Show — the Trace" do
    # The four tabs modelled unordered peers, but a proxied request is a
    # sequence: client -> us -> provider(s) -> back. Two of them were single
    # hops hoisted out of that sequence and stripped of their position, and a
    # third re-rendered the same bodies again per step. The timeline puts every
    # hop in wire order and hangs the proxy's edits on the edges between them,
    # so a change and the request that produced it are the same object.
    defp fallback_log(user) do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      LogsFixtures.log_fixture(router, %{
        status: "fallback",
        final_provider: "moonshot",
        request_headers: Jason.encode!([["anthropic-version", "2023-06-01"]]),
        response_body: Jason.encode!(%{"type" => "message", "content" => []}),
        attempted_steps: [
          %{
            "position" => 0,
            "provider" => "anthropic",
            "model" => "claude-sonnet-4",
            "status" => "error",
            "error" => "rate_limited",
            "http_status" => 429,
            "latency_ms" => 320
          },
          %{
            "position" => 1,
            "provider" => "moonshot",
            "model" => "kimi-k2.5",
            "status" => "success",
            "latency_ms" => 1800,
            "response_body" => Jason.encode!(%{"choices" => []})
          }
        ],
        fidelity_changes: [
          %{
            "channel" => "request_body",
            "name" => "context_management",
            "action" => "dropped",
            "reason" => "unsupported_by_format_conversion",
            "value" => ~s({"edits":[{"type":"clear_tool_uses_20250919"}]}),
            "provider" => "moonshot",
            "step" => 1
          },
          %{
            "channel" => "request_header",
            "name" => "cookie",
            "action" => "dropped",
            "reason" => "not_client_sent",
            "provider" => "anthropic",
            "step" => 0
          }
        ]
      })
    end

    test "every provider attempt is its own hop, in wire order", %{conn: conn, user: user} do
      log = fallback_log(user)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-node-client-request")
      assert has_element?(live, "#trace-node-attempt-0")
      assert has_element?(live, "#trace-node-attempt-1")
      assert has_element?(live, "#trace-node-client-response")
    end

    test "each edit sits under the hop that produced it", %{conn: conn, user: user} do
      # The old panel's "Step" column pointed at a tab three clicks away. Here
      # the change and its evidence are the same object, so a change recorded
      # against the fallback must not appear on the first attempt's edge.
      log = fallback_log(user)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-edge-attempt-0", "cookie")
      assert has_element?(live, "#trace-edge-attempt-1", "context_management")
      refute has_element?(live, "#trace-edge-attempt-0", "context_management")
    end

    test "a dropped field shows the value the client asked for", %{conn: conn, user: user} do
      # We do not store the client's body, so the diff has to be self-sufficient:
      # "context_management dropped" alone cannot answer what was asked for.
      log = fallback_log(user)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert html =~ "clear_tool_uses_20250919"
      assert has_element?(live, "#trace-value-attempt-1-0")
    end

    test "the top node claims only what we actually stored", %{conn: conn, user: user} do
      # The client's request body is not stored. Rendering the normalized IR
      # there as "what you sent" is the mislabeling this redesign exists to fix,
      # so the node offers the headers — which really are theirs — and says so.
      log = fallback_log(user)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert html =~ "You sent"
      assert html =~ "anthropic-version"
      assert has_element?(live, "#trace-node-client-request", "not stored")
    end

    test "an Anthropic client is not labelled openai", %{conn: conn, user: user} do
      # The logged response body is the proxy's OpenAI-shaped IR, not the bytes
      # the egress wrote — reading it alone renamed every Anthropic client's
      # format, which is exactly the kind of confident mislabeling this view was
      # rebuilt to stop. The headers the client sent are theirs, and they say.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_headers: Jason.encode!([["anthropic-version", "2023-06-01"]]),
          response_body: Jason.encode!(%{"choices" => []}),
          attempted_steps: [
            %{"position" => 0, "provider" => "anthropic", "model" => "x", "status" => "success"}
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-node-client-request", "anthropic format")
      refute has_element?(live, "#trace-node-client-request", "openai format")
    end

    test "a failed hop carries its status and a fell-back edge", %{conn: conn, user: user} do
      log = fallback_log(user)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-node-attempt-0", "rate_limited")
      assert html =~ "fell back"
    end

    test "a clean request says so on the edge it applies to", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          fidelity_changes: [],
          final_provider: "anthropic",
          attempted_steps: [
            %{"position" => 0, "provider" => "anthropic", "model" => "x", "status" => "success"}
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert html =~ "Passed through unchanged"
      assert html =~ "every header and field you sent reached anthropic"
    end

    test "the trace offers copy buttons for each end of the hop", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          response_body: Jason.encode!(%{"choices" => [%{"message" => %{"content" => "yo"}}]}),
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "openai",
              "model" => "gpt-4o",
              "status" => "success",
              "request_body" =>
                Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#copy-normalized-request[phx-hook=CopyButton][data-copy]")
      assert has_element?(live, "#copy-response-json[phx-hook=CopyButton][data-copy]")
    end

    test "the normalized request is shown once, on the edge that normalizes it", %{
      conn: conn,
      user: user
    } do
      # `request_body` on an attempt is `state.request` — the same IR for every
      # attempt in the chain. Rendering it inside each node printed N copies of
      # one request-level artifact and left two request bodies per node with
      # nothing saying which one the provider actually got.
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      ir = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      log =
        LogsFixtures.log_fixture(router, %{
          status: "fallback",
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude",
              "status" => "error",
              "error" => "rate_limited",
              "request_body" => ir
            },
            %{
              "position" => 1,
              "provider" => "openai",
              "model" => "gpt-4o",
              "status" => "success",
              "request_body" => ir
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-edge-attempt-0 #trace-normalized-request")
      refute has_element?(live, "#trace-request-body-0")
      refute has_element?(live, "#trace-request-body-1")
    end

    test "an attempt whose request really did change shows its own body", %{
      conn: conn,
      user: user
    } do
      # A midstream fallback reconstructs the request with the partial response
      # already streamed, so that attempt's body genuinely is not the one on the
      # edge. Hoisting the shared IR must not hide the one case where it moved.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          status: "fallback",
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude",
              "status" => "error",
              "error" => "upstream_error",
              "request_body" => Jason.encode!(%{"messages" => [%{"content" => "hi"}]})
            },
            %{
              "position" => 1,
              "provider" => "openai",
              "model" => "gpt-4o",
              "status" => "success",
              "request_body" =>
                Jason.encode!(%{
                  "messages" => [%{"content" => "hi"}, %{"content" => "partial so far"}]
                })
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      refute has_element?(live, "#trace-request-body-0")
      assert has_element?(live, "#trace-request-body-1")
      assert html =~ "partial so far"
    end

    test "a midstream handoff is labeled on the attempt that streamed to the client", %{
      conn: conn,
      user: user
    } do
      # streamed_to_client means the client had already received part of this
      # attempt's answer when it failed — the next attempt continued the same
      # response mid-stream. That is a materially different event from a clean
      # pre-stream fallback and the Trace must say so.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          status: "fallback",
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude-opus-4-8",
              "status" => "error",
              "error" => "unknown",
              "streamed_to_client" => true,
              "partial_content_length" => 324
            },
            %{
              "position" => 1,
              "provider" => "moonshot",
              "model" => "kimi-k2.6",
              "status" => "success"
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-midstream-badge-0")
      refute has_element?(live, "#trace-midstream-badge-1")
      assert html =~ "324"
      assert html =~ "mid-stream"
    end

    test "a clean fallback shows no midstream badge", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          status: "fallback",
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude-opus-4-8",
              "status" => "error",
              "error" => "rate_limited"
            },
            %{
              "position" => 1,
              "provider" => "moonshot",
              "model" => "kimi-k2.6",
              "status" => "success"
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      refute has_element?(live, "#trace-midstream-badge-0")
      refute html =~ "mid-stream"
    end

    test "a payload renders as text and is upgraded to a tree", %{conn: conn, user: user} do
      # The tree is built client-side from the <pre> the server renders, so the
      # markup has to keep carrying the text: that is what a payload which is
      # not JSON falls back to, and what the hook reads instead of a second copy
      # in a data- attribute.
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      ir = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "openai",
              "model" => "gpt-4o",
              "status" => "success",
              "request_body" => ir
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert has_element?(live, "#trace-normalized-json[phx-hook=JsonTree][phx-update=ignore]")
      assert has_element?(live, "#trace-normalized-json [data-json-fallback]")
      assert has_element?(live, "#trace-normalized-controls [data-json-action=expand]")
      assert html =~ "messages"
    end

    test "a converted response is not passed off as the provider's own bytes", %{
      conn: conn,
      user: user
    } do
      # `response_body` on an attempt is what the adapter returned, and the
      # Anthropic adapter runs convert_to_openai_format/1 before we ever see it.
      # "Response Body" under a provider node reads as that provider's bytes.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude",
              "status" => "success",
              "response_body" => Jason.encode!(%{"choices" => []})
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert html =~ "converted"
      assert has_element?(live, "#trace-response-body-0")
    end

    test "an attempt says when the bytes it sent were never recorded", %{conn: conn, user: user} do
      # Only ResponsesAPI records `outbound_body`. Showing the shared IR in its
      # place would assert that those were the bytes on the wire, which is the
      # claim the trace is not allowed to make.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude",
              "status" => "success",
              "request_body" => Jason.encode!(%{"messages" => []})
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      refute has_element?(live, "#trace-outbound-body-0")
      assert html =~ "not recorded"
    end

    test "a failed attempt shows the provider's own error bytes as such", %{
      conn: conn,
      user: user
    } do
      # error_body is `details[:body]` — genuinely raw. It is the one response
      # artifact on an attempt that the provider itself wrote.
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          status: "error",
          attempted_steps: [
            %{
              "position" => 0,
              "provider" => "anthropic",
              "model" => "claude",
              "status" => "error",
              "error" => "rate_limited",
              "error_body" => ~s({"error":"slow down"})
            }
          ]
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")
      html = live |> element("[role=tab][phx-value-tab=trace]") |> render_click()

      assert html =~ "slow down"
      assert html =~ "the provider&#39;s own bytes"
    end

    test "the trace replaces the three hop-shaped tabs", %{conn: conn, user: user} do
      log = fallback_log(user)

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      assert has_element?(live, "[role=tab][phx-value-tab=conversation]")
      assert has_element?(live, "[role=tab][phx-value-tab=trace]")
      refute has_element?(live, "[role=tab][phx-value-tab=raw_request]")
      refute has_element?(live, "[role=tab][phx-value-tab=raw_response]")
      refute has_element?(live, "[role=tab][phx-value-tab=fallback_trace]")
    end
  end

  describe "Show — failed requests" do
    test "the default tab leads with what went wrong", %{conn: conn, user: user} do
      {router, _} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          status: "error",
          http_status: 502,
          request_body: Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]}),
          response_body:
            Jason.encode!(%{
              "error" => %{"message" => "All providers failed", "type" => "upstream_error"}
            }),
          attempted_steps: [
            %{
              "provider" => "anthropic",
              "model" => "claude-sonnet",
              "status" => "error",
              "error" => "auth_error",
              "http_status" => 401,
              "error_body" => ~s({"error":{"message":"invalid x-api-key"}}),
              "latency_ms" => 310
            }
          ]
        })

      {:ok, live, html} = live(conn, ~p"/logs/#{log.id}")

      assert has_element?(live, "#request-failure-panel")
      assert html =~ "no provider returned a response"
      assert html =~ "All providers failed"
      assert html =~ "invalid x-api-key"
    end
  end
end
