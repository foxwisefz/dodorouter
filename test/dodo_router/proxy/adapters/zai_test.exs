defmodule DodoRouter.Proxy.Adapters.ZaiTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Zai
  alias DodoRouter.Routers.RoutingStep

  describe "base_url/1" do
    test "returns coding URL for coding plan" do
      step = %RoutingStep{plan_type: "coding"}

      assert Zai.base_url(step) ==
               "https://api.z.ai/api/coding/paas/v4"
    end

    test "returns standard URL for nil plan" do
      step = %RoutingStep{plan_type: nil}
      assert Zai.base_url(step) == "https://api.z.ai/api/paas/v4"
    end

    test "returns standard URL for other plan types" do
      step = %RoutingStep{plan_type: "standard"}
      assert Zai.base_url(step) == "https://api.z.ai/api/paas/v4"
    end
  end

  describe "parse_sse_chunk/1" do
    test "parses single SSE event" do
      data = "data: {\"id\":\"123\",\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"
      assert {:chunks, [chunk]} = Zai.parse_sse_chunk(data)
      assert chunk["id"] == "123"
    end

    test "parses multiple batched SSE events" do
      data =
        "data: {\"id\":\"1\",\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: {\"id\":\"2\",\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\ndata: {\"id\":\"3\",\"choices\":[{\"delta\":{\"content\":\"c\"}}]}\n\n"

      assert {:chunks, chunks} = Zai.parse_sse_chunk(data)
      assert length(chunks) == 3
      assert Enum.map(chunks, & &1["id"]) == ["1", "2", "3"]
    end

    test "returns :done for [DONE] signal" do
      assert Zai.parse_sse_chunk("data: [DONE]\n\n") == :done
    end

    test "returns chunks_then_done when data ends with [DONE]" do
      data =
        "data: {\"id\":\"final\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

      assert {:chunks_then_done, [chunk]} =
               Zai.parse_sse_chunk(data)

      assert chunk["id"] == "final"
    end

    test "returns :skip for empty data" do
      assert Zai.parse_sse_chunk("") == :skip
      assert Zai.parse_sse_chunk("\n\n") == :skip
    end
  end

  describe "accumulate_tool_calls/2" do
    test "accumulates streamed tool call arguments" do
      existing = %{}

      chunk1 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "function" => %{"name" => "read", "arguments" => ""}
                }
              ]
            }
          }
        ]
      }

      chunk2 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}
              ]
            }
          }
        ]
      }

      chunk3 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "\"/tmp\"}"}}
              ]
            }
          }
        ]
      }

      acc =
        existing
        |> Zai.accumulate_tool_calls(chunk1)
        |> Zai.accumulate_tool_calls(chunk2)
        |> Zai.accumulate_tool_calls(chunk3)

      assert acc[0]["id"] == "call_1"
      assert acc[0]["function"]["name"] == "read"

      assert acc[0]["function"]["arguments"] ==
               "{\"path\":\"/tmp\"}"
    end

    test "handles multiple concurrent tool calls" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "c1",
                  "function" => %{"name" => "a", "arguments" => "{}"}
                },
                %{"index" => 1, "id" => "c2", "function" => %{"name" => "b", "arguments" => "{}"}}
              ]
            }
          }
        ]
      }

      result = Zai.accumulate_tool_calls(%{}, chunk)
      assert result[0]["function"]["name"] == "a"
      assert result[1]["function"]["name"] == "b"
    end
  end

  describe "build_request_body/2" do
    test "sets model from routing step" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "glm-4-plus", provider: "zai"}

      body = Zai.build_request_body(request, step)
      assert body["model"] == "glm-4-plus"
    end

    test "applies step defaults when client doesn't provide
  values" do
      request = %{"messages" => []}
      step = %RoutingStep{model: "glm-4", temperature: 0.7, max_tokens: 4096}

      body = Zai.build_request_body(request, step)
      assert body["temperature"] == 0.7
      assert body["max_tokens"] == 4096
    end

    test "client values take precedence over step defaults" do
      request = %{"messages" => [], "temperature" => 0.9}
      step = %RoutingStep{model: "glm-4", temperature: 0.7}

      body = Zai.build_request_body(request, step)
      assert body["temperature"] == 0.9
    end
  end
end
