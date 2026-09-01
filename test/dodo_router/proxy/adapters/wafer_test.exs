defmodule DodoRouter.Proxy.Adapters.WaferTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Proxy.Adapters.Wafer
  alias DodoRouter.Routers.RoutingStep

  describe "adapter_config/0" do
    test "registers under the wafer slug with the Wafer Pass base URL" do
      config = Wafer.adapter_config()

      assert config.slug == "wafer"
      assert config.key_slugs == ["wafer"]
      assert config.endpoints == %{"wafer" => "https://pass.wafer.ai/v1"}
      assert config.request_format == :openai
      assert config.endpoint_path == "/chat/completions"
    end
  end

  describe "OpenAICompatible.build_request_body via Wafer" do
    test "injects step reasoning_effort as top-level reasoning_effort, verbatim" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "GLM-5.2", reasoning_effort: "high"}

      body = OpenAICompatible.build_request_body(request, step, reasoning_format: :openai)
      assert body["reasoning_effort"] == "high"
      assert body["model"] == "GLM-5.2"
    end

    test "does not override client reasoning_effort" do
      request = %{"messages" => [], "reasoning_effort" => "low"}
      step = %RoutingStep{model: "Kimi-K2.6", reasoning_effort: "high"}

      body = OpenAICompatible.build_request_body(request, step, reasoning_format: :openai)
      assert body["reasoning_effort"] == "low"
    end

    test "forwards a client thinking toggle untouched" do
      # Wafer accepts thinking {"type": "enabled"|"disabled"} as an
      # equivalent reasoning control; it must survive sanitization.
      request = %{"messages" => [], "thinking" => %{"type" => "disabled"}}
      step = %RoutingStep{model: "GLM-5.2", reasoning_effort: nil}

      body = OpenAICompatible.build_request_body(request, step, reasoning_format: :openai)
      assert body["thinking"] == %{"type" => "disabled"}
    end
  end

  describe "usage seam" do
    test "Wafer's observed cached token reporting reaches extract_usage" do
      # Verbatim shape from a live cache-hit probe (2026-09-02,
      # scripts/wafer_probe.sh): OpenAI-style prompt_tokens_details plus a
      # redundant top-level cached_tokens. OpenAICompatible passes usage
      # through untouched, so extraction must find it with no renaming step.
      response = %{
        "usage" => %{
          "prompt_tokens" => 23_010,
          "completion_tokens" => 5,
          "total_tokens" => 23_015,
          "cached_tokens" => 22_528,
          "completion_tokens_details" => %{"reasoning_tokens" => 1},
          "prompt_tokens_details" => %{"cached_tokens" => 22_528}
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.prompt_tokens == 23_010
      assert usage.cache_read_tokens == 22_528
    end
  end

  describe "context overflow (not detectable on Wafer)" do
    # Verbatim body from a live oversized-prompt probe (2026-09-02,
    # scripts/wafer_probe.sh). Wafer returns this exact code and message for
    # ANY model-side rejection — an invalid role and a bad tool_choice combo
    # produce it too — so mapping it to :context_overflow would misclassify
    # real client errors. It must stay :bad_request, which still falls back;
    # see AGENTS.md's Known Provider Patterns.
    @wafer_rejection %{
      "error" => %{
        "message" => "The model request was rejected. Check the request and try again.",
        "type" => "invalid_request_error",
        "param" => nil,
        "code" => "model_request_rejected"
      }
    }

    test "the generic rejection stays :bad_request, never :context_overflow" do
      assert Adapter.categorize_error(400, @wafer_rejection) == :bad_request
    end

    test "and :bad_request still advances the fallback chain" do
      assert Adapter.should_fallback?(:bad_request)
    end
  end

  describe "request_headers/2" do
    test "authenticates with a bearer token and forwards client headers" do
      headers = Wafer.request_headers("wfr_test", [{"x-client-trace", "abc"}])

      assert {"Authorization", "Bearer wfr_test"} in headers
      assert {"x-client-trace", "abc"} in headers
    end
  end
end
