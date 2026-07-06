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

    test "model reasoning is viewable but collapsed", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body: Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "2+2?"}]}),
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

    test "raw request and response tabs offer a copy button", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body: Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]}),
          response_body:
            Jason.encode!(%{
              "choices" => [%{"message" => %{"role" => "assistant", "content" => "yo"}}]
            })
        })

      {:ok, live, _html} = live(conn, ~p"/logs/#{log.request_id}")

      live |> element("button", "Original Request") |> render_click()
      assert has_element?(live, "#copy-request-json[phx-hook=CopyButton][data-copy]")

      live |> element("button", "Final Response") |> render_click()
      assert has_element?(live, "#copy-response-json[phx-hook=CopyButton][data-copy]")
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
      # 400 cached of (400 cached + 500 billed) = 44%, never >100%
      assert html =~ "(44%)"
      # new (uncached) input and output are separated so the cached figure
      # can't dwarf an ambiguous "Tokens" total
      assert html =~ "Input (new)"
      assert html =~ "Output"
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
