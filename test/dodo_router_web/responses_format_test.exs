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

    test "preserves client reasoning effort" do
      responses = %{
        "model" => "gpt-5.5",
        "input" => "Hello",
        "reasoning" => %{"effort" => "high", "summary" => "auto"}
      }

      result = ResponsesFormat.to_openai_params(responses)

      assert result["reasoning_effort"] == "high"
    end

    test "omits reasoning_effort when client sends none" do
      result = ResponsesFormat.to_openai_params(%{"model" => "gpt-5.5", "input" => "Hello"})
      refute Map.has_key?(result, "reasoning_effort")

      result =
        ResponsesFormat.to_openai_params(%{
          "model" => "gpt-5.5",
          "input" => "Hello",
          "reasoning" => %{"effort" => nil}
        })

      refute Map.has_key?(result, "reasoning_effort")
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
    test "emits output_item.added and content_part.added before the first output_text.delta" do
      # Regression test: Responses API clients (e.g. Codex CLI) track an "active
      # item" client-side and reject a delta that arrives before an
      # output_item.added/content_part.added pair for it, logging something like
      # "OutputTextDelta without active item" — even though DodoRouter's own
      # request/response was entirely correct. See the docs' Codex CLI section.
      openai_chunk =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"content" => "Hello"}}]
          }) <> "\n\n"

      assert {:ok, events} =
               ResponsesFormat.convert_sse_chunk(openai_chunk, "lifecycle-start-#{unique()}")

      assert [item_added, content_part_added, delta] = events
      assert item_added =~ "event: response.output_item.added"
      assert content_part_added =~ "event: response.content_part.added"
      assert delta =~ "event: response.output_text.delta"
      assert delta =~ "Hello"
    end

    test "does not repeat output_item.added/content_part.added on later deltas of the same stream" do
      request_id = "lifecycle-repeat-#{unique()}"

      first_chunk =
        "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Hel"}}]}) <> "\n\n"

      second_chunk =
        "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "lo"}}]}) <> "\n\n"

      assert {:ok, [_item_added, _part_added, _delta1]} =
               ResponsesFormat.convert_sse_chunk(first_chunk, request_id)

      assert {:ok, [delta2]} = ResponsesFormat.convert_sse_chunk(second_chunk, request_id)
      assert delta2 =~ "event: response.output_text.delta"
      assert delta2 =~ "lo"
    end

    test "emits output_text.done/content_part.done/output_item.done with the full text on finish_reason" do
      request_id = "lifecycle-done-#{unique()}"

      first_chunk =
        "data: " <> Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Hi"}}]}) <> "\n\n"

      final_chunk =
        "data: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}) <> "\n\n"

      assert {:ok, _} = ResponsesFormat.convert_sse_chunk(first_chunk, request_id)
      assert {:ok, events} = ResponsesFormat.convert_sse_chunk(final_chunk, request_id)

      assert [text_done, part_done, item_done] = events
      assert text_done =~ "event: response.output_text.done"
      assert text_done =~ "Hi"
      assert part_done =~ "event: response.content_part.done"
      assert item_done =~ "event: response.output_item.done"
    end

    test "emits nothing on finish_reason if no item was ever started" do
      request_id = "lifecycle-empty-#{unique()}"

      final_chunk =
        "data: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}) <> "\n\n"

      assert :skip = ResponsesFormat.convert_sse_chunk(final_chunk, request_id)
    end

    test "converts OpenAI SSE content delta to Responses API output_text.delta" do
      openai_chunk =
        "data: " <>
          Jason.encode!(%{
            "choices" => [%{"delta" => %{"content" => "Hello"}}]
          }) <> "\n\n"

      assert {:ok, events} =
               ResponsesFormat.convert_sse_chunk(openai_chunk, "content-delta-#{unique()}")

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

      assert :skip = ResponsesFormat.convert_sse_chunk(openai_chunk, "empty-delta-#{unique()}")
    end

    test "skips [DONE] markers" do
      assert :skip =
               ResponsesFormat.convert_sse_chunk("data: [DONE]\n\n", "done-marker-#{unique()}")
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
