defmodule DodoRouter.ProxyTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Logs
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Proxy
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  describe "dispatch/3 with :steps override and :log_mode :sync" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      provider_key = ProvidersFixtures.provider_key_fixture(user)

      step = %RoutingStep{
        id: Ecto.UUID.generate(),
        router_id: router.id,
        position: 0,
        provider: "test_provider",
        model: "test-model",
        plan_type: "standard",
        provider_key: provider_key,
        provider_key_id: provider_key.id
      }

      request = %{
        "model" => "ignored-by-routing",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      %{user: user, router: router, step: step, request: request}
    end

    test "without override the router has no routing configured", ctx do
      assert {:error, :no_routing_configured} = Proxy.dispatch(ctx.router, ctx.request)
    end

    test "dispatches through the provided steps instead of the router chain", ctx do
      assert {:ok, response, _meta} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step])

      assert get_in(response, ["choices", Access.at(0), "message", "content"]) ==
               "Hello from test-model"
    end

    test "meta log is nil unless log_mode is :sync", ctx do
      assert {:ok, _response, meta} = Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step])
      assert meta.log == nil
    end

    test "log_mode :sync returns the persisted log in dispatch meta", ctx do
      assert {:ok, _response, %{log: %RequestLog{} = log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step], log_mode: :sync)

      assert log.final_model == "test-model"
      assert log.status == "success"
      assert Repo.get!(RequestLog, log.id)
    end

    test "threads replayed_from_id into the persisted log", ctx do
      original = LogsFixtures.log_fixture(ctx.router)

      assert {:ok, _response, %{log: %RequestLog{} = log}} =
               Proxy.dispatch(ctx.router, ctx.request,
                 steps: [ctx.step],
                 log_mode: :sync,
                 replayed_from_id: original.id
               )

      assert log.replayed_from_id == original.id
      assert Logs.list_replays(original) |> Enum.map(& &1.id) == [log.id]
    end

    test "fingerprints the provider payload before retained bodies are truncated", ctx do
      text = String.duplicate("private context ", 20_000)
      request = put_in(ctx.request, ["messages", Access.at(0), "content"], text)

      assert {:ok, _, %{log: log}} =
               Proxy.dispatch(ctx.router, request,
                 steps: [ctx.step],
                 log_mode: :sync
               )

      assert log.cache_fingerprint["messages"] |> hd() |> Map.fetch!("bytes") > byte_size(text)
      refute Jason.encode!(log.cache_fingerprint) =~ "private"
      refute Map.has_key?(log.cache_fingerprint, "branch")
      refute Map.has_key?(log.cache_fingerprint, "turn")
      assert is_integer(log.cache_fingerprint["started_at_ms"])
      assert log.cache_fingerprint["finished_at_ms"] >= log.cache_fingerprint["started_at_ms"]
      assert log.cache_diagnosis["cause"] == "unknown"

      assert log.cache_diagnosis["current"]["routing_context"]["provider_key_id"] ==
               ctx.step.provider_key_id

      assert log.cache_diagnosis["current"]["served_model"] == "test-model"

      # Logging retention does not affect the signature or diagnosis.
      updated =
        log
        |> Ecto.Changeset.change(request_body: nil, response_body: nil, attempted_steps: [])
        |> Repo.update!()

      assert updated.cache_fingerprint == log.cache_fingerprint
      assert updated.cache_diagnosis == log.cache_diagnosis
    end

    test "counts other in-flight requests on this router without claiming a cache race", ctx do
      other = Ecto.UUID.generate()
      DodoRouter.Activity.request_started(ctx.router.id, other)

      try do
        assert {:ok, _, %{log: log}} =
                 Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step], log_mode: :sync)

        assert log.cache_diagnosis["current"]["other_in_flight_router_requests"] == 1
        refute log.cache_diagnosis["cause"] == "parallel_race"
      after
        DodoRouter.Activity.request_completed(ctx.router.id, other)
      end
    end

    test "fallback fingerprints the serving attempt, and streaming also records it", ctx do
      failed = %{ctx.step | model: "fail-model", id: Ecto.UUID.generate()}

      assert {:ok, _, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [failed, ctx.step], log_mode: :sync)

      expected =
        DodoRouter.Logs.CacheDiagnostics.fingerprint(
          Jason.decode!(List.last(log.attempted_steps)["outbound_body"]),
          ctx.router.id
        )

      assert log.cache_fingerprint["model"] == expected["model"]
      assert log.cache_fingerprint["messages"] == expected["messages"]

      assert {:ok, _, %{log: streamed}} =
               Proxy.dispatch_streaming(ctx.router, ctx.request, fn _chunk -> :ok end,
                 steps: [ctx.step],
                 log_mode: :sync
               )

      assert streamed.cache_fingerprint["messages"] == log.cache_fingerprint["messages"]
    end

    test "key health is recorded before dispatch returns", ctx do
      assert {:ok, _response, _meta} = Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step])

      # Health tracking is fire-and-forget in production, but a task that
      # outlives its caller loses the sandbox connection it borrowed — so
      # in test it has to be finished by the time dispatch returns.
      key = Repo.get!(DodoRouter.Providers.ProviderKey, ctx.step.provider_key_id)
      assert key.status == "valid"
      assert key.last_ok_at
    end

    test "sync logging persists an error log retrievable by request_id when the step fails",
         ctx do
      keyless_step = %{ctx.step | provider_key: nil, provider_key_id: nil}
      request_id = Ecto.UUID.generate()

      assert {:error, :all_providers_failed, _attempts} =
               Proxy.dispatch(ctx.router, ctx.request,
                 steps: [keyless_step],
                 log_mode: :sync,
                 request_id: request_id
               )

      assert %RequestLog{status: "error"} = Logs.get_log_by_request_id(request_id)
    end
  end

  describe "dispatch/3 when the adapter raises mid-chain" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      provider_key = ProvidersFixtures.provider_key_fixture(user)

      step = %RoutingStep{
        id: Ecto.UUID.generate(),
        router_id: router.id,
        position: 0,
        provider: "test_provider",
        model: "test-model",
        plan_type: "standard",
        provider_key: provider_key,
        provider_key_id: provider_key.id
      }

      request = %{
        "model" => "ignored-by-routing",
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "__crash__" => true
      }

      %{router: router, step: step, request: request}
    end

    test "re-raises after decrementing activity and persisting an error log", ctx do
      request_id = Ecto.UUID.generate()

      assert_raise ArgumentError, "test adapter crash", fn ->
        Proxy.dispatch(ctx.router, ctx.request,
          steps: [ctx.step],
          log_mode: :sync,
          request_id: request_id
        )
      end

      assert DodoRouter.Activity.get_router_counts(ctx.router.id) == {0, 0}

      assert %RequestLog{status: "error"} = log = Logs.get_log_by_request_id(request_id)
      assert log.response_body =~ "test adapter crash"
    end

    test "streaming dispatch also decrements activity on crash", ctx do
      request = Map.put(ctx.request, "stream", true)

      assert_raise ArgumentError, "test adapter crash", fn ->
        Proxy.dispatch_streaming(ctx.router, request, fn _chunk -> :ok end, steps: [ctx.step])
      end

      assert DodoRouter.Activity.get_router_counts(ctx.router.id) == {0, 0}
    end
  end

  describe "plan-aware cost calculation" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      coding_key =
        ProvidersFixtures.provider_key_fixture(user, %{provider_slug: "moonshot_coding"})

      step = %RoutingStep{
        id: Ecto.UUID.generate(),
        router_id: router.id,
        position: 0,
        provider: "test_provider",
        model: "test-model",
        plan_type: "coding",
        provider_key: coding_key,
        provider_key_id: coding_key.id
      }

      {:ok, _platform} =
        DodoRouter.Models.create_model(%{
          provider_slug: "test_provider",
          model_id: "test-model",
          display_name: "Test Model",
          input_price_per_million: Decimal.new("1.0"),
          output_price_per_million: Decimal.new("2.0")
        })

      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

      %{user: user, router: router, step: step, request: request}
    end

    test "a plan catalog row wins over the provider's platform pricing", ctx do
      {:ok, _plan} =
        DodoRouter.Models.create_model(%{
          provider_slug: "moonshot_coding",
          model_id: "test-model",
          display_name: "Test Model (plan)",
          input_price_per_million: Decimal.new("0"),
          output_price_per_million: Decimal.new("0")
        })

      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step], log_mode: :sync)

      assert Decimal.eq?(log.estimated_cost_usd, Decimal.new(0))

      # The would-cost figure prices the same tokens at metered API rates:
      # 10 prompt tokens at $1/M plus 5 completion tokens at $2/M.
      assert Decimal.eq?(log.list_cost_usd, Decimal.new("0.00002"))
    end

    test "falls back to the provider's platform pricing without a plan row", ctx do
      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step], log_mode: :sync)

      assert Decimal.compare(log.estimated_cost_usd, Decimal.new(0)) == :gt
      assert Decimal.eq?(log.list_cost_usd, log.estimated_cost_usd)
    end

    test "subscription key slugs report zero cost even when platform pricing exists", ctx do
      oauth_key =
        ProvidersFixtures.provider_key_fixture(ctx.user, %{provider_slug: "anthropic_oauth"})

      step = %{ctx.step | provider_key: oauth_key, provider_key_id: oauth_key.id}

      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [step], log_mode: :sync)

      assert Decimal.eq?(log.estimated_cost_usd, Decimal.new(0))
      assert Decimal.compare(log.list_cost_usd, Decimal.new(0)) == :gt
    end

    test "reasoning text the client's format cannot carry is recorded, not silently lost", ctx do
      step = %{ctx.step | model: "reasoning-model"}

      # An Anthropic-format client served by an OpenAI-family provider: the
      # egress has no signed representation for reasoning_content, so the
      # drop must reach the log (dodo_router-2s4).
      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request,
                 steps: [step],
                 log_mode: :sync,
                 client_format: :anthropic
               )

      assert Enum.any?(log.fidelity_changes, fn change ->
               change["name"] == "reasoning_content" and change["action"] == "dropped" and
                 change["value"] =~ "thought"
             end)

      # An OpenAI-format client gets the IR verbatim — nothing is lost, so
      # nothing may claim to be.
      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [step], log_mode: :sync)

      refute Enum.any?(log.fidelity_changes || [], &(&1["name"] == "reasoning_content"))
    end

    test "dropped query parameters are recorded as their own fidelity channel", ctx do
      # Query params are the fourth loss channel (headers, request body,
      # response fields) — never forwarded, and until dodo_router-69m never
      # recorded either.
      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request,
                 steps: [ctx.step],
                 log_mode: :sync,
                 dropped_query_params: %{"beta" => "true"}
               )

      assert Enum.any?(log.fidelity_changes, fn change ->
               change["channel"] == "query_params" and change["name"] == "beta" and
                 change["action"] == "dropped" and
                 change["reason"] == "query_params_not_forwarded" and
                 change["value"] =~ "true"
             end)
    end

    test "unknown usage prices as nil, not zero", ctx do
      # A pricing row exists, so the only reason for a nil cost is the
      # absent token counts — zero would mean "free", not "unknown".
      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "test_provider",
          model_id: "no-usage-model",
          display_name: "No Usage Model",
          input_price_per_million: Decimal.new("1.0"),
          output_price_per_million: Decimal.new("2.0")
        })

      step = %{ctx.step | model: "no-usage-model"}

      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [step], log_mode: :sync)

      assert log.prompt_tokens == nil
      assert log.estimated_cost_usd == nil
      assert log.list_cost_usd == nil
    end

    test "unknown usage on a subscription key also prices as nil", ctx do
      oauth_key =
        ProvidersFixtures.provider_key_fixture(ctx.user, %{provider_slug: "anthropic_oauth"})

      step = %{
        ctx.step
        | model: "no-usage-model",
          provider_key: oauth_key,
          provider_key_id: oauth_key.id
      }

      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [step], log_mode: :sync)

      assert log.estimated_cost_usd == nil
      assert log.list_cost_usd == nil
    end

    test "list cost is nil when the model has no metered catalog row", ctx do
      DodoRouter.Repo.delete_all(DodoRouter.Models.Model)

      {:ok, _plan} =
        DodoRouter.Models.create_model(%{
          provider_slug: "moonshot_coding",
          model_id: "test-model",
          display_name: "Test Model (plan)",
          input_price_per_million: Decimal.new("0"),
          output_price_per_million: Decimal.new("0")
        })

      assert {:ok, _resp, %{log: log}} =
               Proxy.dispatch(ctx.router, ctx.request, steps: [ctx.step], log_mode: :sync)

      assert Decimal.eq?(log.estimated_cost_usd, Decimal.new(0))
      assert log.list_cost_usd == nil
    end
  end

  describe "error_response/1" do
    test "returns 400 with standardized context overflow error" do
      attempts = [
        %{error: "context_overflow", latency_ms: 100},
        %{error: "context_overflow", latency_ms: 150}
      ]

      {status, response} = Proxy.error_response(attempts)

      assert status == 400
      assert response.error.message == "Input exceeds context window of this model"
      assert response.error.type == "invalid_request_error"
      assert response.error.code == "context_length_exceeded"
      assert response.error.attempts == 2
    end

    test "returns 502 with generic provider error for non-context-overflow" do
      attempts = [
        %{error: "rate_limited", latency_ms: 100},
        %{error: "server_error", latency_ms: 150}
      ]

      {status, response} = Proxy.error_response(attempts)

      assert status == 502
      assert response.error.message == "All providers failed"
      assert response.error.type == "provider_error"
      assert response.error.last_error == "server_error"
      assert response.error.attempts == 2
    end

    test "handles single context overflow attempt" do
      attempts = [%{error: "context_overflow", latency_ms: 100}]

      {status, response} = Proxy.error_response(attempts)

      assert status == 400
      assert response.error.attempts == 1
    end
  end

  describe "streaming_error_payload/1" do
    test "returns context overflow payload for streaming" do
      attempts = [%{error: "context_overflow", latency_ms: 100}]

      payload = Proxy.streaming_error_payload(attempts)

      assert payload.error.message == "Input exceeds context window of this model"
      assert payload.error.type == "context_overflow"
    end

    test "returns generic failure payload for non-context-overflow" do
      attempts = [%{error: "timeout", latency_ms: 100}]

      payload = Proxy.streaming_error_payload(attempts)

      assert payload.error.message == "All providers failed"
      refute Map.has_key?(payload.error, :type)
    end
  end

  describe "truncate_body/1" do
    test "handles large text content truncation" do
      # Use text with spaces so it doesn't match base64 pattern
      large_content = String.duplicate("hello world ", 20_000)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => large_content}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_text_truncated" in flags
      assert String.length(truncated["messages"] |> hd() |> Map.get("content")) < 210_000
    end

    test "keeps large agent system prompts intact below the cap" do
      # Coding-agent system prompts routinely run 50-100KB; they must survive
      content = String.duplicate("agent instructions ", 5_000)

      request = %{"messages" => [%{"role" => "system", "content" => content}]}

      {truncated, flags} = Proxy.truncate_body(request)

      assert flags == []
      assert truncated["messages"] |> hd() |> Map.get("content") == content
    end

    test "handles base64 content truncation" do
      # Valid base64 string (length divisible by 4, only base64 chars)
      base64_content = String.duplicate("QUJD", 500)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => base64_content}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_base64_truncated" in flags
    end

    test "handles nil body" do
      {body, flags} = Proxy.truncate_body(nil)

      assert body == nil
      assert flags == []
    end

    test "leaves small content unchanged" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello world"}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert flags == []
      assert truncated["messages"] |> hd() |> Map.get("content") == "Hello world"
    end

    test "truncates base64 data URIs inside image_url content parts" do
      data_uri = "data:image/png;base64," <> String.duplicate("QUJD", 1_000)

      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "look at this"},
              %{"type" => "image_url", "image_url" => %{"url" => data_uri}}
            ]
          }
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_base64_truncated" in flags

      [text_part, image_part] = truncated["messages"] |> hd() |> Map.get("content")
      assert text_part["text"] == "look at this"
      assert image_part["image_url"]["url"] =~ "truncated"
      refute image_part["image_url"]["url"] =~ "QUJD"
    end

    test "truncates large text parts inside content lists" do
      big_text = String.duplicate("hello world ", 20_000)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => [%{"type" => "text", "text" => big_text}]}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_text_truncated" in flags
      [part] = truncated["messages"] |> hd() |> Map.get("content")
      assert String.length(part["text"]) < 210_000
    end

    test "leaves small content parts and http image URLs unchanged" do
      content = [
        %{"type" => "text", "text" => "hi"},
        %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/x.png"}}
      ]

      request = %{"messages" => [%{"role" => "user", "content" => content}]}

      {truncated, flags} = Proxy.truncate_body(request)

      assert flags == []
      assert truncated["messages"] |> hd() |> Map.get("content") == content
    end
  end

  describe "attempted_steps JSON serialization" do
    test "handles outbound_headers with tuples" do
      # Simulates what FallbackChain produces when adapters return headers as tuples
      attempted_steps = [
        %{
          provider: "moonshot",
          model: "kimi-k2",
          endpoint: "https://api.kimi.com/coding/v1/chat/completions",
          status: "success",
          latency_ms: 1234,
          outbound_headers: [
            {"Authorization", "Bearer sk-test"},
            {"Content-Type", "application/json"}
          ],
          response_headers: [
            {"content-type", "application/json"}
          ]
        }
      ]

      # This is what Proxy.log_request does before DB insert
      processed = Proxy.stringify_keys(attempted_steps)
      json = Jason.encode!(processed)
      decoded = Jason.decode!(json)

      step = hd(decoded)
      assert step["provider"] == "moonshot"

      assert step["outbound_headers"] == [
               ["Authorization", "Bearer sk-test"],
               ["Content-Type", "application/json"]
             ]

      assert step["response_headers"] == [["content-type", "application/json"]]
    end
  end

  describe "build_log_response_body/2" do
    test "uses successful response when present" do
      response = %{"choices" => [%{"message" => %{"content" => "Hello"}}]}
      last_step = %{error_body: nil}

      {body, flags} = Proxy.build_log_response_body(response, last_step)

      assert body["choices"] |> hd() |> get_in(["message", "content"]) == "Hello"
      assert flags == []
    end

    test "uses JSON error body from last step when no successful response" do
      error_json = ~s({"error": {"message": "Invalid key", "type": "auth_error"}})
      last_step = %{error_body: error_json}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body["error"]["message"] == "Invalid key"
      assert flags == []
    end

    test "uses map error body from last step" do
      last_step = %{error_body: %{"error" => %{"message" => "Rate limited"}}}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body["error"]["message"] == "Rate limited"
      assert flags == []
    end

    test "stores raw error string when JSON parsing fails" do
      raw_error = "not valid json at all"
      last_step = %{error_body: raw_error}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body["_raw_error"] == raw_error
      assert flags == []
    end

    test "returns nil when no error body exists" do
      last_step = %{}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body == nil
      assert flags == []
    end
  end
end
