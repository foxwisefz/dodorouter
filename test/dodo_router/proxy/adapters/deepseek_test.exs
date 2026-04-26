defmodule DodoRouter.Proxy.Adapters.DeepSeekTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.DeepSeek

  describe "transform_request/1" do
    test "flattens content arrays to strings" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "hello"}]
          }
        ]
      }

      result = DeepSeek.transform_request(request)
      msg = hd(result["messages"])
      assert msg["content"] == "hello"
    end
  end

  describe "normalize_thinking_param/1" do
    test "normalizes thinking with budget_tokens to simple enabled" do
      request = %{
        "messages" => [],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 10000}
      }

      result = DeepSeek.normalize_thinking_param(request)
      assert result["thinking"] == %{"type" => "enabled"}
      refute Map.has_key?(result["thinking"], "budget_tokens")
    end

    test "converts reasoning_effort to thinking enabled" do
      request = %{"messages" => [], "reasoning_effort" => "high"}
      result = DeepSeek.normalize_thinking_param(request)
      assert result["thinking"] == %{"type" => "enabled"}
      refute Map.has_key?(result, "reasoning_effort")
    end

    test "removes thinking when type is disabled" do
      request = %{"messages" => [], "thinking" => %{"type" => "disabled"}}
      result = DeepSeek.normalize_thinking_param(request)
      refute Map.has_key?(result, "thinking")
    end

    test "removes reasoning_effort when none" do
      request = %{"messages" => [], "reasoning_effort" => "none"}
      result = DeepSeek.normalize_thinking_param(request)
      refute Map.has_key?(result, "reasoning_effort")
      refute Map.has_key?(result, "thinking")
    end

    test "no-ops when no thinking or reasoning_effort" do
      request = %{"messages" => []}
      result = DeepSeek.normalize_thinking_param(request)
      refute Map.has_key?(result, "thinking")
      refute Map.has_key?(result, "reasoning_effort")
    end
  end
end
