defmodule DodoRouter.Proxy.Adapters.XAITest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.XAI
  alias DodoRouter.Proxy.Adapter

  describe "transform_request/2" do
    test "strips name from all messages" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi", "name" => "Alice"},
          %{"role" => "assistant", "content" => "hello", "name" => "Bot"}
        ]
      }

      result = XAI.transform_request(request, "grok-3")
      for msg <- result["messages"] do
        refute Map.has_key?(msg, "name")
      end
    end

    test "removes strict from tool definitions" do
      request = %{
        "messages" => [],
        "tools" => [
          %{
            "function" => %{
              "name" => "test",
              "strict" => true,
              "parameters" => %{}
            }
          }
        ]
      }

      result = XAI.transform_request(request, "grok-3")
      tool = hd(result["tools"])
      refute Map.has_key?(tool["function"], "strict")
    end

    test "removes stop for grok-3-mini" do
      request = %{"messages" => [], "stop" => ["\n"]}
      result = XAI.transform_request(request, "grok-3-mini")
      refute Map.has_key?(result, "stop")
    end

    test "keeps stop for grok-3" do
      request = %{"messages" => [], "stop" => ["\n"]}
      result = XAI.transform_request(request, "grok-3")
      assert result["stop"] == ["\n"]
    end

    test "removes frequency_penalty for grok-4" do
      request = %{"messages" => [], "frequency_penalty" => 0.5}
      result = XAI.transform_request(request, "grok-4")
      refute Map.has_key?(result, "frequency_penalty")
    end
  end

  describe "transform_response/1" do
    test "fixes empty finish_reason when tool_calls present" do
      response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [%{"id" => "c1", "function" => %{"name" => "test"}}]
            },
            "finish_reason" => nil
          }
        ]
      }

      {:ok, result} = XAI.transform_response({:ok, response})
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"
    end

    test "passes through error tuples" do
      error = {:error, :timeout, %{latency_ms: 100}}
      assert XAI.transform_response(error) == error
    end
  end
end
