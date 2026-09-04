defmodule DodoRouter.Proxy.Adapters.ResponsesAPITest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.ResponsesAPI
  alias DodoRouter.Routers.RoutingStep

  describe "build_request_body/2" do
    test "converts messages to Responses API input format" do
      request = %{
        "messages" => [
          %{"role" => "system", "content" => "You are helpful"},
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      assert body["model"] == "gpt-5.5"
      assert body["store"] == false
      refute Map.has_key?(body, "messages")
      refute Map.has_key?(body, "max_tokens")

      [system, user] = body["input"]
      assert system["role"] == "system"
      assert system["content"] == "You are helpful"
      assert user["role"] == "user"
      assert [%{"type" => "input_text", "text" => "Hello"}] = user["content"]
    end

    test "converts multi-block system content to input_text parts" do
      # AnthropicFormat carries multi-block system content as a parts array
      # (with per-part cache_control) so Anthropic steps keep their cache
      # breakpoints. When such a request falls back to a Responses step, the
      # parts must become input_text — the API rejects type "text" on input.
      request = %{
        "messages" => [
          %{
            "role" => "system",
            "content" => [
              %{
                "type" => "text",
                "text" => "You are helpful",
                "cache_control" => %{"type" => "ephemeral"}
              },
              %{"type" => "text", "text" => "Env info"}
            ]
          },
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      [system | _] = body["input"]
      assert system["role"] == "system"

      assert system["content"] == [
               %{"type" => "input_text", "text" => "You are helpful"},
               %{"type" => "input_text", "text" => "Env info"}
             ]
    end

    test "converts assistant messages with content" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hi"},
          %{"role" => "assistant", "content" => "Hello back"}
        ]
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      assistant_item =
        Enum.find(body["input"], fn item ->
          item["role"] == "assistant"
        end)

      assert [%{"type" => "output_text", "text" => "Hello back"}] = assistant_item["content"]
    end

    test "converts tool messages to function_call_output" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "What's the weather?"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_123",
                "type" => "function",
                "function" => %{"name" => "get_weather", "arguments" => "{\"city\": \"SF\"}"}
              }
            ]
          },
          %{"role" => "tool", "tool_call_id" => "call_123", "content" => "Sunny, 72F"}
        ]
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      function_call =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call"
        end)

      assert function_call["call_id"] == "call_123"
      assert function_call["name"] == "get_weather"
      assert function_call["arguments"] == "{\"city\": \"SF\"}"

      function_output =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call_output"
        end)

      assert function_output["call_id"] == "call_123"
      assert function_output["output"] == "Sunny, 72F"
    end

    test "injects reasoning.effort from routing step" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}
      step = %RoutingStep{model: "gpt-5.5", reasoning_effort: "high"}

      body = ResponsesAPI.build_request_body(request, step)
      assert body["reasoning"] == %{"effort" => "high"}
    end

    test "does not override client reasoning" do
      request = %{"messages" => [], "reasoning" => %{"effort" => "low"}}
      step = %RoutingStep{model: "gpt-5.5", reasoning_effort: "high"}

      body = ResponsesAPI.build_request_body(request, step)
      assert body["reasoning"] == %{"effort" => "low"}
    end

    test "client reasoning_effort (from Responses inbound conversion) wins over step default" do
      request = %{"messages" => [], "reasoning_effort" => "low"}
      step = %RoutingStep{model: "gpt-5.5", reasoning_effort: "high"}

      body = ResponsesAPI.build_request_body(request, step)
      assert body["reasoning"] == %{"effort" => "low"}
    end
  end

  describe "tool/function calling" do
    test "converts tools to Responses API format" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "description" => "Get weather",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ]
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      [tool] = body["tools"]
      assert tool["type"] == "function"
      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get weather"
    end

    test "passes through temperature and top_p" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.5,
        "top_p" => 0.9
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      assert body["temperature"] == 0.5
      assert body["top_p"] == 0.9
    end

    test "handles user content as list of parts" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's in this image?"},
              %{"type" => "image_url", "image_url" => %{"url" => "http://example.com/img.png"}}
            ]
          }
        ]
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      [user] = body["input"]
      assert user["role"] == "user"

      [text_part, image_part] = user["content"]
      assert text_part["type"] == "input_text"
      assert text_part["text"] == "What's in this image?"
      assert image_part["type"] == "image_url"
    end

    test "strips max_tokens (unsupported by Responses API)" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 100
      }

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      refute Map.has_key?(body, "max_tokens")
    end

    test "always sets store to false" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{model: "gpt-5.5"}
      body = ResponsesAPI.build_request_body(request, step)

      assert body["store"] == false
    end
  end

  describe "process_events/2 - SSE conversion" do
    test "converts output_text.delta to OpenAI content chunks" do
      acc = %{
        model: "gpt-5.5",
        content: "",
        tool_calls: %{},
        usage: nil,
        finish_reason: nil,
        first_chunk_time: 1,
        sse_buffer: ""
      }

      events = [
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{"type" => "response.output_text.delta", "delta" => " world"}
      ]

      {new_acc, chunks} = ResponsesAPI.process_events(acc, events)

      assert new_acc.content == "Hello world"

      assert Enum.all?(chunks, fn chunk ->
               String.contains?(chunk, "data: ") and String.contains?(chunk, "\"delta\"")
             end)

      assert hd(chunks) =~ "Hello"
      assert Enum.at(chunks, 1) =~ "world"
    end

    test "extracts usage from response.completed" do
      acc = %{
        model: "gpt-5.5",
        content: "Hi",
        tool_calls: %{},
        usage: nil,
        finish_reason: nil,
        first_chunk_time: 1,
        sse_buffer: ""
      }

      events = [
        %{
          "type" => "response.completed",
          "response" => %{
            "usage" => %{
              "input_tokens" => 12,
              "output_tokens" => 9,
              "total_tokens" => 21
            }
          }
        }
      ]

      {new_acc, chunks} = ResponsesAPI.process_events(acc, events)

      assert new_acc.usage["prompt_tokens"] == 12
      assert new_acc.usage["completion_tokens"] == 9
      assert new_acc.usage["total_tokens"] == 21
      assert new_acc.finish_reason == "stop"
      assert hd(chunks) =~ "finish_reason"
      assert hd(chunks) =~ "stop"
    end

    test "handles function_call output items" do
      acc = %{
        model: "gpt-5.5",
        content: "",
        tool_calls: %{},
        usage: nil,
        finish_reason: nil,
        first_chunk_time: 1,
        sse_buffer: ""
      }

      events = [
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "get_weather"
          }
        }
      ]

      {new_acc, chunks} = ResponsesAPI.process_events(acc, events)

      [{0, entry}] = Map.to_list(new_acc.tool_calls)
      assert entry["id"] == "call_abc"
      assert entry["function"]["name"] == "get_weather"

      assert hd(chunks) =~ "get_weather"
      assert hd(chunks) =~ "tool_calls"
    end

    test "correlates argument deltas by output item id" do
      acc = %{
        model: "gpt-5.5",
        content: "",
        tool_calls: %{},
        usage: nil,
        finish_reason: nil,
        first_chunk_time: 1,
        sse_buffer: ""
      }

      events = [
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "id" => "fc_abc",
            "call_id" => "call_abc",
            "name" => "get_weather"
          }
        },
        %{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "fc_abc",
          "delta" => ~s({"city":)
        },
        %{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "fc_abc",
          "delta" => ~s("SF"})
        }
      ]

      {new_acc, chunks} = ResponsesAPI.process_events(acc, events)

      assert get_in(new_acc.tool_calls, [0, "id"]) == "call_abc"
      assert get_in(new_acc.tool_calls, [0, "function", "arguments"]) == ~s({"city":"SF"})
      assert Enum.any?(chunks, &String.contains?(&1, ~s("arguments":"{\\"city\\":")))

      [tool_call] =
        ResponsesAPI.build_final_response(new_acc, %{})["choices"]
        |> hd()
        |> get_in(["message", "tool_calls"])

      assert tool_call["id"] == "call_abc"
      refute Map.has_key?(tool_call, :item_id)
    end

    test "ignores unrelated event types" do
      acc = %{
        model: "gpt-5.5",
        content: "test",
        tool_calls: %{},
        usage: nil,
        finish_reason: nil,
        first_chunk_time: 1,
        sse_buffer: ""
      }

      events = [
        %{"type" => "response.created"},
        %{"type" => "response.in_progress"},
        %{"type" => "response.content_part.added"}
      ]

      {new_acc, chunks} = ResponsesAPI.process_events(acc, events)
      assert new_acc == acc
      assert chunks == []
    end
  end

  describe "build_final_response/2" do
    test "builds standard OpenAI response format" do
      acc = %{
        model: "gpt-5.5",
        content: "Hello there!",
        tool_calls: %{},
        usage: %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15},
        finish_reason: "stop",
        first_chunk_time: 100
      }

      meta = %{
        "ttfb_ms" => 100,
        "upload_ms" => nil,
        "payload_size_bytes" => 50,
        "provider_processing_ms" => nil
      }

      response = ResponsesAPI.build_final_response(acc, meta)

      assert response["model"] == "gpt-5.5"

      [choice] = response["choices"]
      assert choice["message"]["role"] == "assistant"
      assert choice["message"]["content"] == "Hello there!"
      assert choice["finish_reason"] == "stop"

      assert response["usage"]["prompt_tokens"] == 10
      assert response["_meta"]["ttfb_ms"] == 100
    end

    test "includes tool_calls in message when present" do
      acc = %{
        model: "gpt-5.5",
        content: "",
        tool_calls: %{
          0 => %{
            "id" => "call_123",
            "type" => "function",
            "function" => %{"name" => "get_weather", "arguments" => "{\"city\": \"SF\"}"}
          }
        },
        usage: nil,
        finish_reason: "tool_calls",
        first_chunk_time: 100
      }

      response = ResponsesAPI.build_final_response(acc, %{})

      [choice] = response["choices"]
      [tool_call] = choice["message"]["tool_calls"]
      assert tool_call["function"]["name"] == "get_weather"
    end

    test "omits usage when nil" do
      acc = %{
        model: "gpt-5.5",
        content: "Hi",
        tool_calls: %{},
        usage: nil,
        finish_reason: "stop",
        first_chunk_time: 50
      }

      response = ResponsesAPI.build_final_response(acc, %{})

      refute Map.has_key?(response, "usage")
    end
  end

  describe "convert_usage/1" do
    test "maps Responses API usage fields to OpenAI format" do
      usage = %{
        "input_tokens" => 100,
        "output_tokens" => 50,
        "total_tokens" => 150
      }

      result = ResponsesAPI.convert_usage(usage)

      assert result["prompt_tokens"] == 100
      assert result["completion_tokens"] == 50
      assert result["total_tokens"] == 150
    end

    test "renames input_tokens_details to prompt_tokens_details for cache extraction" do
      usage = %{
        "input_tokens" => 100,
        "output_tokens" => 50,
        "total_tokens" => 150,
        "input_tokens_details" => %{"cached_tokens" => 80}
      }

      result = ResponsesAPI.convert_usage(usage)

      assert result["prompt_tokens_details"]["cached_tokens"] == 80
    end

    test "convert_usage output satisfies Adapter.extract_usage for cache tokens" do
      usage = %{
        "input_tokens" => 100,
        "output_tokens" => 50,
        "total_tokens" => 150,
        "input_tokens_details" => %{"cached_tokens" => 80}
      }

      converted = ResponsesAPI.convert_usage(usage)
      extracted = Adapter.extract_usage(%{"usage" => converted})

      assert extracted.cache_read_tokens == 80
    end
  end
end
