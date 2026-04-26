defmodule DodoRouter.Proxy.Adapters.AnthropicTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Anthropic
  alias DodoRouter.Routers.RoutingStep

  describe "build_anthropic_request/2" do
    test "extracts system message to top-level system field" do
      request = %{
        "messages" => [
          %{"role" => "system", "content" => "You are helpful"},
          %{"role" => "user", "content" => "hi"}
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["system"] == "You are helpful"
      roles = Enum.map(body["messages"], & &1["role"])
      assert "system" not in roles
    end

    test "does not add system field when no system message" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      refute Map.has_key?(body, "system")
    end

    test "converts tool_calls in assistant messages to Anthropic format" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "use tool"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => "{\"path\": \"/tmp\"}"}
              }
            ]
          }
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      content = assistant_msg["content"]
      tool_use = Enum.find(content, &(&1["type"] == "tool_use"))
      assert tool_use["id"] == "call_1"
      assert tool_use["name"] == "read_file"
      assert tool_use["input"] == %{"path" => "/tmp"}
    end

    test "converts tool result messages to user role with tool_result content" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{"role" => "tool", "content" => "file contents", "tool_call_id" => "call_1"}
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      tool_msg = Enum.find(body["messages"], fn m ->
        is_list(m["content"]) and Enum.any?(m["content"], &(&1["type"] == "tool_result"))
      end)

      assert tool_msg["role"] == "user"
      tool_result = hd(tool_msg["content"])
      assert tool_result["tool_use_id"] == "call_1"
      assert tool_result["content"] == "file contents"
    end

    test "converts tools to Anthropic format" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "tools" => [
          %{
            "function" => %{
              "name" => "read_file",
              "description" => "Read a file",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      tool = hd(body["tools"])
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file"
      assert Map.has_key?(tool, "input_schema")
      refute Map.has_key?(tool, "parameters")
    end

    test "maps stop to stop_sequences" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}], "stop" => ["\n"]}
      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["stop_sequences"] == ["\n"]
    end

    test "defaults max_tokens to 4096" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["max_tokens"] == 4096
    end
  end

  describe "convert_to_openai_format/1" do
    test "converts text response" do
      anthropic_response = %{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      result = Anthropic.convert_to_openai_format(anthropic_response)

      assert get_in(result, ["choices", Access.at(0), "message", "content"]) == "Hello!"
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "stop"
      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "converts tool_use response" do
      anthropic_response = %{
        "content" => [
          %{"type" => "text", "text" => "Using tool"},
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "read_file",
            "input" => %{"path" => "/tmp"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      result = Anthropic.convert_to_openai_format(anthropic_response)

      message = get_in(result, ["choices", Access.at(0), "message"])
      assert message["content"] == "Using tool"
      assert length(message["tool_calls"]) == 1
      tc = hd(message["tool_calls"])
      assert tc["id"] == "call_1"
      assert tc["function"]["name"] == "read_file"
      assert Jason.decode!(tc["function"]["arguments"]) == %{"path" => "/tmp"}
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"
    end

    test "maps stop_reason values correctly" do
      assert get_in(
        Anthropic.convert_to_openai_format(%{"content" => [], "stop_reason" => "end_turn"}),
        ["choices", Access.at(0), "finish_reason"]
      ) == "stop"

      assert get_in(
        Anthropic.convert_to_openai_format(%{"content" => [], "stop_reason" => "max_tokens"}),
        ["choices", Access.at(0), "finish_reason"]
      ) == "length"
    end
  end
end
