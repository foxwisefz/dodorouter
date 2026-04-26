defmodule DodoRouter.Proxy.Adapters.MistralTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Mistral

  describe "transform_request/1" do
    test "strips name from non-tool messages only" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi", "name" => "Alice"},
          %{"role" => "tool", "content" => "result", "tool_call_id" => "c1", "name" => "func"}
        ]
      }

      result = Mistral.transform_request(request)
      user_msg = Enum.find(result["messages"], &(&1["role"] == "user"))
      tool_msg = Enum.find(result["messages"], &(&1["role"] == "tool"))

      refute Map.has_key?(user_msg, "name")
      assert Map.has_key?(tool_msg, "name")
    end

    test "cleans tool schemas" do
      request = %{
        "messages" => [],
        "tools" => [
          %{
            "function" => %{
              "name" => "test",
              "parameters" => %{
                "$id" => "test-id",
                "$schema" => "https://json-schema.org",
                "additionalProperties" => false,
                "type" => "object",
                "properties" => %{
                  "name" => %{"type" => "string", "$id" => "nested-id"}
                }
              },
              "strict" => true
            }
          }
        ]
      }

      result = Mistral.transform_request(request)
      tool = hd(result["tools"])
      params = tool["function"]["parameters"]

      refute Map.has_key?(params, "$id")
      refute Map.has_key?(params, "$schema")
      refute Map.has_key?(params, "additionalProperties")
      refute Map.has_key?(tool["function"], "strict")
      refute Map.has_key?(params["properties"]["name"], "$id")
      assert Map.has_key?(params, "type")
    end

    test "filters empty assistant messages" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{"role" => "assistant", "content" => ""},
          %{"role" => "user", "content" => "hello"}
        ]
      }

      result = Mistral.transform_request(request)
      roles = Enum.map(result["messages"], & &1["role"])
      assert roles == ["user", "user"]
    end

    test "keeps assistant messages with tool_calls even if content empty" do
      request = %{
        "messages" => [
          %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "c1"}]}
        ]
      }

      result = Mistral.transform_request(request)
      assert length(result["messages"]) == 1
    end

    test "flattens text-only content arrays to strings" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "hello"},
              %{"type" => "text", "text" => " world"}
            ]
          }
        ]
      }

      result = Mistral.transform_request(request)
      msg = hd(result["messages"])
      assert msg["content"] == "hello world"
    end

    test "preserves content arrays with images" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "describe"},
              %{"type" => "image_url", "image_url" => %{"url" => "http://example.com/img.png"}}
            ]
          }
        ]
      }

      result = Mistral.transform_request(request)
      msg = hd(result["messages"])
      assert is_list(msg["content"])
    end
  end
end
