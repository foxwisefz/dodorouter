defmodule DodoRouterWeb.AnthropicFormatTest do
  use ExUnit.Case, async: true

  alias DodoRouterWeb.AnthropicFormat

  describe "to_openai_params/1" do
    test "converts basic Anthropic request to OpenAI format" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_tokens" => 1024
      }

      result = AnthropicFormat.to_openai_params(anthropic)

      assert result["model"] == "claude-sonnet-4-20250514"
      assert result["messages"] == [%{"role" => "user", "content" => "Hello"}]
      assert result["max_tokens"] == 1024
    end

    test "extracts system prompt from top-level field" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "system" => "You are a helpful assistant.",
        "max_tokens" => 1024
      }

      result = AnthropicFormat.to_openai_params(anthropic)

      assert List.first(result["messages"]) == %{
               "role" => "system",
               "content" => "You are a helpful assistant."
             }
    end

    test "converts tool_result messages nested in user content blocks" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "user", "content" => "Check the weather"},
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Let me check."},
              %{
                "type" => "tool_use",
                "id" => "toolu_123",
                "name" => "get_weather",
                "input" => %{"city" => "SF"}
              }
            ]
          },
          %{
            "role" => "user",
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "toolu_123", "content" => "Sunny, 72F"}
            ]
          }
        ],
        "max_tokens" => 1024
      }

      result = AnthropicFormat.to_openai_params(anthropic)
      messages = result["messages"]

      tool_msg = Enum.find(messages, &(&1["role"] == "tool"))
      assert tool_msg["tool_call_id"] == "toolu_123"
      assert tool_msg["content"] == "Sunny, 72F"
    end

    test "converts multiple tool_results in single user message to separate tool messages" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{"role" => "user", "content" => "Do stuff"},
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "Bash:0", "name" => "bash", "input" => %{}},
              %{"type" => "tool_use", "id" => "Bash:1", "name" => "bash", "input" => %{}}
            ]
          },
          %{
            "role" => "user",
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "Bash:0", "content" => "output1"},
              %{"type" => "tool_result", "tool_use_id" => "Bash:1", "content" => "output2"}
            ]
          }
        ],
        "max_tokens" => 1024
      }

      result = AnthropicFormat.to_openai_params(anthropic)
      messages = result["messages"]

      tool_messages = Enum.filter(messages, &(&1["role"] == "tool"))
      assert length(tool_messages) == 2

      ids = Enum.map(tool_messages, & &1["tool_call_id"])
      assert "Bash:0" in ids
      assert "Bash:1" in ids
    end

    test "converts assistant tool_use blocks to OpenAI tool_calls" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Let me look that up."},
              %{
                "type" => "tool_use",
                "id" => "tool_abc",
                "name" => "search",
                "input" => %{"query" => "test"}
              }
            ]
          }
        ],
        "max_tokens" => 1024
      }

      result = AnthropicFormat.to_openai_params(anthropic)
      assistant_msg = Enum.find(result["messages"], &(&1["role"] == "assistant"))

      assert assistant_msg["content"] == "Let me look that up."
      assert length(assistant_msg["tool_calls"]) == 1

      tc = hd(assistant_msg["tool_calls"])
      assert tc["id"] == "tool_abc"
      assert tc["function"]["name"] == "search"
      assert Jason.decode!(tc["function"]["arguments"]) == %{"query" => "test"}
    end

    test "converts Anthropic tools to OpenAI function tools" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 1024,
        "tools" => [
          %{
            "name" => "get_weather",
            "description" => "Get weather",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{"city" => %{"type" => "string"}}
            }
          }
        ]
      }

      result = AnthropicFormat.to_openai_params(anthropic)

      assert length(result["tools"]) == 1
      tool = hd(result["tools"])
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "get_weather"
      assert tool["function"]["parameters"]["properties"]["city"]["type"] == "string"
    end

    test "passes through stream, temperature, top_p, stop_sequences" do
      anthropic = %{
        "model" => "claude-sonnet-4-20250514",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 1024,
        "stream" => true,
        "temperature" => 0.7,
        "top_p" => 0.9,
        "stop_sequences" => ["END"]
      }

      result = AnthropicFormat.to_openai_params(anthropic)

      assert result["stream"] == true
      assert result["temperature"] == 0.7
      assert result["top_p"] == 0.9
      assert result["stop"] == ["END"]
    end
  end

  describe "from_openai_response/1" do
    test "converts basic OpenAI response to Anthropic format" do
      openai = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      result = AnthropicFormat.from_openai_response(openai)

      assert result["type"] == "message"
      assert result["role"] == "assistant"
      assert result["stop_reason"] == "end_turn"
      assert result["content"] == [%{"type" => "text", "text" => "Hello!"}]
      assert result["usage"]["input_tokens"] == 10
      assert result["usage"]["output_tokens"] == 5
    end

    test "converts tool_calls response" do
      openai = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Let me search.",
              "tool_calls" => [
                %{
                  "id" => "call_123",
                  "type" => "function",
                  "function" => %{
                    "name" => "search",
                    "arguments" => Jason.encode!(%{"q" => "test"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30}
      }

      result = AnthropicFormat.from_openai_response(openai)

      assert result["stop_reason"] == "tool_use"

      [%{"type" => "text", "text" => "Let me search."}, %{"type" => "tool_use"} = tool_block] =
        result["content"]

      assert tool_block["id"] == "call_123"
      assert tool_block["name"] == "search"
      assert tool_block["input"] == %{"q" => "test"}
    end

    test "converts finish_reason length to max_tokens" do
      openai = %{
        "choices" => [
          %{"message" => %{"content" => "truncated"}, "finish_reason" => "length"}
        ]
      }

      result = AnthropicFormat.from_openai_response(openai)
      assert result["stop_reason"] == "max_tokens"
    end
  end

  describe "convert_sse_chunk/1" do
    test "converts OpenAI SSE content delta to Anthropic content_block_delta" do
      openai_chunk =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"content" => "Hello"}}]
          }) <> "\n\n"

      assert {:ok, events} = AnthropicFormat.convert_sse_chunk(openai_chunk)
      assert length(events) == 1

      assert events
             |> Enum.any?(fn e ->
               String.contains?(e, "content_block_delta") and String.contains?(e, "Hello")
             end)
    end

    test "skips empty content deltas" do
      openai_chunk =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"role" => "assistant"}}]
          }) <> "\n\n"

      assert :skip = AnthropicFormat.convert_sse_chunk(openai_chunk)
    end

    test "skips [DONE] markers" do
      assert :skip = AnthropicFormat.convert_sse_chunk("data: [DONE]\n\n")
    end
  end
end
