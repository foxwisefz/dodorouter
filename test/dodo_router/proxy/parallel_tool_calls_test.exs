defmodule DodoRouter.Proxy.ParallelToolCallsTest do
  @moduledoc """
  `parallel_tool_calls` is the client saying "run one tool at a time". Both
  ingress converters produce it and the Anthropic adapter consumes it, but the
  shared request allowlist did not list it — so the same request kept the
  intent on an Anthropic step and lost it on every OpenAI-family step,
  including every fallback.

  These tests walk the whole seam rather than the allowlist alone: a field can
  be allowed by `sanitize_request/1` and still be dropped by an adapter's own
  request builder.
  """
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters
  alias DodoRouter.Routers.RoutingStep

  @request %{
    "messages" => [%{"role" => "user", "content" => "hi"}],
    "tools" => [
      %{"type" => "function", "function" => %{"name" => "read", "parameters" => %{}}}
    ],
    "tool_choice" => "auto",
    "parallel_tool_calls" => false
  }

  defp step(provider, model \\ "some-model") do
    %RoutingStep{provider: provider, model: model}
  end

  describe "OpenAI-family egress keeps the client's intent" do
    test "OpenAI" do
      body = Adapters.OpenAI.build_request_body(@request, step("openai", "gpt-4o"))
      assert body["parallel_tool_calls"] == false
    end

    test "OpenAI-compatible shared path (Groq, Mistral, xAI, DeepSeek)" do
      body =
        Adapters.OpenAICompatible.build_request_body(@request, step("groq"), provider: "groq")

      assert body["parallel_tool_calls"] == false
    end

    test "z.ai" do
      body = Adapters.Zai.build_request_body(@request, step("zai", "glm-4.6"))
      assert body["parallel_tool_calls"] == false
    end

    test "Moonshot" do
      body = Adapters.Moonshot.build_request_body(@request, step("moonshot", "kimi-k2.5"))
      assert body["parallel_tool_calls"] == false
    end
  end

  describe "Anthropic egress already honoured it and still does" do
    test "folds back into tool_choice.disable_parallel_tool_use" do
      body = Adapters.Anthropic.build_anthropic_request(@request, step("anthropic", "claude-x"))

      assert body["tool_choice"]["disable_parallel_tool_use"] == true
      refute Map.has_key?(body, "parallel_tool_calls")
    end
  end

  describe "the field is never invented" do
    test "a request that never mentioned it does not grow one" do
      request = Map.delete(@request, "parallel_tool_calls")

      for body <- [
            Adapters.OpenAI.build_request_body(request, step("openai", "gpt-4o")),
            Adapters.OpenAICompatible.build_request_body(request, step("groq"), provider: "groq"),
            Adapters.Zai.build_request_body(request, step("zai", "glm-4.6")),
            Adapters.Moonshot.build_request_body(request, step("moonshot", "kimi-k2.5"))
          ] do
        refute Map.has_key?(body, "parallel_tool_calls")
      end
    end
  end
end
