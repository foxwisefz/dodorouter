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
    test "OpenAI-style cached token reporting reaches extract_usage" do
      # Wafer's surface is OpenAI-compatible and OpenAICompatible passes the
      # usage object through untouched, so cache extraction must find the
      # OpenAI field names without any renaming step in between.
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 20,
          "total_tokens" => 120,
          "prompt_tokens_details" => %{"cached_tokens" => 80}
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.prompt_tokens == 100
      assert usage.cache_read_tokens == 80
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
