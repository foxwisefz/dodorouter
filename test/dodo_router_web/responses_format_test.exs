defmodule DodoRouterWeb.ResponsesFormatTest do
  use ExUnit.Case, async: true

  alias DodoRouterWeb.ResponsesFormat

  describe "to_openai_params/1" do
    test "converts string input to single user message" do
      responses = %{
        "model" => "gpt-4o",
        "input" => "Hello!"
      }

      result = ResponsesFormat.to_openai_params(responses)

      assert result["model"] == "gpt-4o"
      assert result["messages"] == [%{"role" => "user", "content" => "Hello!"}]
    end

    test "converts array input to messages" do
      responses = %{
        "model" => "gpt-4o",
        "input" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi!"}
        ]
      }

      result = ResponsesFormat.to_openai_params(responses)

      assert result["messages"] == [
               %{"role" => "user", "content" => "Hello"},
               %{"role" => "assistant", "content" => "Hi!"}
             ]
    end

    test "adds instructions as system message" do
      responses = %{
        "model" => "gpt-4o",
        "input" => "Hello",
        "instructions" => "Be helpful"
      }

      result = ResponsesFormat.to_openai_params(responses)

      assert List.first(result["messages"]) == %{
               "role" => "system",
               "content" => "Be helpful"
             }
    end

    test "passes through optional params" do
      responses = %{
        "model" => "gpt-4o",
        "input" => "Hello",
        "stream" => true,
        "temperature" => 0.7,
        "top_p" => 0.9,
        "max_output_tokens" => 1024,
        "tool_choice" => "auto",
        "parallel_tool_calls" => false
      }

      result = ResponsesFormat.to_openai_params(responses)

      assert result["stream"] == true
      assert result["temperature"] == 0.7
      assert result["top_p"] == 0.9
      assert result["max_tokens"] == 1024
      assert result["tool_choice"] == "auto"
      assert result["parallel_tool_calls"] == false
    end

    test "handles nil input" do
      responses = %{
        "model" => "gpt-4o"
      }

      result = ResponsesFormat.to_openai_params(responses)

      assert result["messages"] == []
    end
  end

  describe "from_openai_response/2" do
    test "converts basic OpenAI response to Responses API format" do
      openai = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15},
        "model" => "gpt-4o"
      }

      result = ResponsesFormat.from_openai_response(openai, "test-id")

      assert result["id"] == "resp_test-id"
      assert result["object"] == "response"
      assert result["status"] == "completed"
      assert result["model"] == "gpt-4o"

      assert [%{"type" => "message", "role" => "assistant", "content" => content_parts}] =
               result["output"]

      assert content_parts == [
               %{"type" => "output_text", "text" => "Hello!", "annotations" => []}
             ]

      assert result["output_text"] == "Hello!"
      assert result["usage"]["input_tokens"] == 10
      assert result["usage"]["output_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "converts tool_calls response" do
      openai = %{
        "choices" => [
          %{
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
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30},
        "model" => "gpt-4o"
      }

      result = ResponsesFormat.from_openai_response(openai, "test-id")

      assert [%{"type" => "message", "content" => content_parts}] = result["output"]

      assert length(content_parts) == 2

      text_part = Enum.find(content_parts, &(&1["type"] == "output_text"))
      assert text_part["text"] == "Let me search."

      tool_part = Enum.find(content_parts, &(&1["type"] == "tool_call"))
      assert tool_part["call_id"] == "call_123"
      assert tool_part["name"] == "search"
      assert tool_part["arguments"] == ~s({"q":"test"})
    end

    test "handles empty content" do
      openai = %{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => nil},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{},
        "model" => "gpt-4o"
      }

      result = ResponsesFormat.from_openai_response(openai, "test-id")

      assert [%{"type" => "message", "content" => []}] = result["output"]
      assert result["output_text"] == ""
    end
  end

  describe "convert_sse_chunk/2" do
    test "converts OpenAI SSE content delta to Responses API output_text.delta" do
      openai_chunk =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"content" => "Hello"}}]
          }) <> "\n\n"

      assert {:ok, events} = ResponsesFormat.convert_sse_chunk(openai_chunk, "test-id")
      assert length(events) == 1

      assert events
             |> Enum.any?(fn e ->
               String.contains?(e, "response.output_text.delta") and String.contains?(e, "Hello")
             end)
    end

    test "skips empty content deltas" do
      openai_chunk =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"role" => "assistant"}}]
          }) <> "\n\n"

      assert :skip = ResponsesFormat.convert_sse_chunk(openai_chunk, "test-id")
    end

    test "skips [DONE] markers" do
      assert :skip = ResponsesFormat.convert_sse_chunk("data: [DONE]\n\n", "test-id")
    end
  end
end
