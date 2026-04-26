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

    test "does not include stream_options (ZAI doesn't support it)" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "glm-4-plus", provider: "zai"}

      body = Zai.build_request_body(request, step)
      refute Map.has_key?(body, "stream_options")
    end
  end

  describe "parse_raw_error/1" do
    test "returns nil for nil" do
      assert Zai.parse_raw_error(nil) == nil
    end

    test "parses JSON error body from streaming error response" do
      raw = "{\"error\":{\"message\":\"Invalid API key\",\"type\":\"invalid_request_error\"}}"
      result = Zai.parse_raw_error(raw)
      assert result["error"]["message"] == "Invalid API key"
    end

    test "returns raw string when not valid JSON" do
      raw = "some plain error"
      result = Zai.parse_raw_error(raw)
      assert result == "some plain error"
    end

    test "decompresses gzip data before parsing" do
      json = "{\"error\":{\"message\":\"auth failed\"}}"
      gzipped = :zlib.gzip(json)
      result = Zai.parse_raw_error(gzipped)
      assert result["error"]["message"] == "auth failed"
    end
  end
end
