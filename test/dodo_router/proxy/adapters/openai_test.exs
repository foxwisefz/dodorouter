defmodule DodoRouter.Proxy.Adapters.OpenAITest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.OpenAI
  alias DodoRouter.Routers.RoutingStep

  describe "build_request_body/2" do
    test "sets model from routing step" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "gpt-4o"}

      body = OpenAI.build_request_body(request, step)
      assert body["model"] == "gpt-4o"
    end

    test "sanitizes non-standard fields" do
      request = %{
        "messages" => [],
        "router_slug" => "my-router",
        "temperature" => 0.7
      }

      step = %RoutingStep{model: "gpt-4o"}
      body = OpenAI.build_request_body(request, step)

      refute Map.has_key?(body, "router_slug")
      assert body["temperature"] == 0.7
    end

    test "normalizes max_completion_tokens" do
      request = %{"messages" => [], "max_completion_tokens" => 100}
      step = %RoutingStep{model: "gpt-4o"}

      body = OpenAI.build_request_body(request, step)
      assert body["max_tokens"] == 100
      refute Map.has_key?(body, "max_completion_tokens")
    end
  end
end
