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

      assert body["system"] == [%{"type" => "text", "text" => "You are helpful"}]
      roles = Enum.map(body["messages"], & &1["role"])
      assert "system" not in roles
    end

    test "extracts system message with content blocks to top-level system field" do
      request = %{
        "messages" => [
          %{
            "role" => "system",
            "content" => [
              %{
                "type" => "text",
                "text" => "You are helpful",
                "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
              }
            ]
          },
          %{"role" => "user", "content" => "hi"}
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["system"] == [
               %{
                 "type" => "text",
                 "text" => "You are helpful",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               }
             ]

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

      tool_msg =
        Enum.find(body["messages"], fn m ->
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
               Anthropic.convert_to_openai_format(%{
                 "content" => [],
                 "stop_reason" => "end_turn"
               }),
               ["choices", Access.at(0), "finish_reason"]
             ) == "stop"

      assert get_in(
               Anthropic.convert_to_openai_format(%{
                 "content" => [],
                 "stop_reason" => "max_tokens"
               }),
               ["choices", Access.at(0), "finish_reason"]
             ) == "length"
    end
  end

  describe "streaming tool calls" do
    @tool_use_events [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Let me check."}
      },
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_01",
          "name" => "read_file",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "\"/tmp\"}"}
      },
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"input_tokens" => 100, "output_tokens" => 30}
      }
    ]

    defp parse_chunks(chunks) do
      Enum.map(chunks, fn "data: " <> rest ->
        rest |> String.trim() |> Jason.decode!()
      end)
    end

    test "forwards tool_use blocks as OpenAI tool_call delta chunks" do
      acc = Anthropic.initial_stream_acc()
      {_acc, chunks} = Anthropic.process_anthropic_events(acc, @tool_use_events)

      deltas = parse_chunks(chunks) |> Enum.map(&get_in(&1, ["choices", Access.at(0), "delta"]))

      start_delta =
        Enum.find(deltas, fn d ->
          get_in(d, ["tool_calls", Access.at(0), "id"]) == "toolu_01"
        end)

      assert start_delta, "expected a tool_calls delta chunk carrying the tool id"
      assert get_in(start_delta, ["tool_calls", Access.at(0), "function", "name"]) == "read_file"
      assert get_in(start_delta, ["tool_calls", Access.at(0), "index"]) == 0

      streamed_args =
        deltas
        |> Enum.map(&get_in(&1, ["tool_calls", Access.at(0), "function", "arguments"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.join()

      assert Jason.decode!(streamed_args) == %{"path" => "/tmp"}
    end

    test "includes accumulated tool_calls in the final OpenAI response" do
      acc = Anthropic.initial_stream_acc()
      {acc, _chunks} = Anthropic.process_anthropic_events(acc, @tool_use_events)

      response =
        Anthropic.build_final_openai_response(acc, %{
          payload_size_bytes: 0,
          upload_ms: nil,
          provider_processing_ms: nil
        })

      choice = get_in(response, ["choices", Access.at(0)])
      assert choice["finish_reason"] == "tool_calls"

      assert [tc] = choice["message"]["tool_calls"]
      assert tc["id"] == "toolu_01"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "read_file"
      assert Jason.decode!(tc["function"]["arguments"]) == %{"path" => "/tmp"}
    end

    test "accumulates multiple parallel tool calls with distinct indexes" do
      events = [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_a",
            "name" => "read",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"a\":1}"}
        },
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_b",
            "name" => "write",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"b\":2}"}
        },
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}, "usage" => nil}
      ]

      acc = Anthropic.initial_stream_acc()
      {acc, _chunks} = Anthropic.process_anthropic_events(acc, events)

      response =
        Anthropic.build_final_openai_response(acc, %{
          payload_size_bytes: 0,
          upload_ms: nil,
          provider_processing_ms: nil
        })

      assert [tc_a, tc_b] = get_in(response, ["choices", Access.at(0), "message", "tool_calls"])
      assert tc_a["id"] == "toolu_a"
      assert Jason.decode!(tc_a["function"]["arguments"]) == %{"a" => 1}
      assert tc_b["id"] == "toolu_b"
      assert Jason.decode!(tc_b["function"]["arguments"]) == %{"b" => 2}
    end

    test "text-only streams still omit tool_calls from the final response" do
      events = [
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hi"}
        },
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => nil}
      ]

      acc = Anthropic.initial_stream_acc()
      {acc, _chunks} = Anthropic.process_anthropic_events(acc, events)

      response =
        Anthropic.build_final_openai_response(acc, %{
          payload_size_bytes: 0,
          upload_ms: nil,
          provider_processing_ms: nil
        })

      message = get_in(response, ["choices", Access.at(0), "message"])
      assert message["content"] == "Hi"
      refute Map.has_key?(message, "tool_calls")
    end
  end

  describe "edge cases" do
    test "merges consecutive tool_result messages (same role)" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "use tools"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "c1",
                "type" => "function",
                "function" => %{"name" => "f1", "arguments" => "{}"}
              },
              %{
                "id" => "c2",
                "type" => "function",
                "function" => %{"name" => "f2", "arguments" => "{}"}
              }
            ]
          },
          %{"role" => "tool", "content" => "result1", "tool_call_id" => "c1"},
          %{"role" => "tool", "content" => "result2", "tool_call_id" => "c2"},
          %{"role" => "user", "content" => "thanks"}
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      tool_msg =
        Enum.find(body["messages"], fn m ->
          is_list(m["content"]) and Enum.any?(m["content"], &(&1["type"] == "tool_result"))
        end)

      assert tool_msg["role"] == "user"
      tool_results = Enum.filter(tool_msg["content"], &(&1["type"] == "tool_result"))
      assert length(tool_results) == 2
      ids = Enum.map(tool_results, & &1["tool_use_id"]) |> Enum.sort()
      assert ids == ["c1", "c2"]
    end

    test "handles malformed JSON in tool_call arguments gracefully" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "c1",
                "type" => "function",
                "function" => %{"name" => "test", "arguments" => "not valid json{{{"}
              }
            ]
          }
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      tool_use = Enum.find(assistant_msg["content"], &(&1["type"] == "tool_use"))
      assert tool_use["input"] == %{}
    end

    test "handles empty assistant content with tool_calls by using placeholder" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "c1",
                "type" => "function",
                "function" => %{"name" => "f", "arguments" => "{}"}
              }
            ]
          }
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert is_list(assistant_msg["content"])
      assert length(assistant_msg["content"]) == 1
      assert hd(assistant_msg["content"])["type"] == "tool_use"
    end

    test "injects step reasoning_effort as output_config.effort" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "claude-opus-5", reasoning_effort: "xhigh"}

      body = Anthropic.build_anthropic_request(request, step)

      assert body["output_config"]["effort"] == "xhigh"
      assert body["thinking"] == %{"type" => "adaptive"}
      refute Map.has_key?(body["thinking"], "budget_tokens")
      assert body["max_tokens"] == 4096
    end

    test "a client reasoning_effort outranks the step default" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "reasoning_effort" => "low"
      }

      step = %RoutingStep{model: "claude-opus-5", reasoning_effort: "max"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["output_config"]["effort"] == "low"
    end

    test "step effort does not displace a client response_format" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"schema" => %{"type" => "object"}}
        }
      }

      step = %RoutingStep{model: "claude-opus-5", reasoning_effort: "high"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["output_config"]["effort"] == "high"

      assert body["output_config"]["format"] == %{
               "type" => "json_schema",
               "schema" => %{"type" => "object"}
             }
    end

    test "preserves client thinking when provided" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 999}
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514", reasoning_effort: "high"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["thinking"]["budget_tokens"] == 999
    end

    test "forwards a client thinking.type=disabled block as sent" do
      # Probed live 2026-08-16 (dodo_router-cit): Sonnet 5 accepts an explicit
      # disable, and omission would leave the adaptive default in charge —
      # thinking ON for the very request that turned it off. Only Fable 5
      # rejects disabled; that case is covered in its own describe.
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "thinking" => %{"type" => "disabled"}
      }

      step = %RoutingStep{model: "claude-sonnet-5"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["thinking"] == %{"type" => "disabled"}
    end

    test "client thinking.type=disabled still suppresses step-level effort injection" do
      # The :anthropic effort injection sets thinking.type=adaptive, which
      # would silently override the client's disable.
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "thinking" => %{"type" => "disabled"}
      }

      step = %RoutingStep{model: "claude-sonnet-5", reasoning_effort: "high"}
      body = Anthropic.build_anthropic_request(request, step)

      assert body["thinking"] == %{"type" => "disabled"}
      refute get_in(body, ["output_config", "effort"])
    end
  end

  describe "tool_choice translation (build_anthropic_request/2)" do
    defp anthropic_tool_choice(request_extras) do
      %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      |> Map.merge(request_extras)
      |> Anthropic.build_anthropic_request(%RoutingStep{model: "claude-sonnet-5"})
    end

    test "\"auto\" maps to the Anthropic auto form" do
      assert anthropic_tool_choice(%{"tool_choice" => "auto"})["tool_choice"] ==
               %{"type" => "auto"}
    end

    test "\"required\" maps to any" do
      assert anthropic_tool_choice(%{"tool_choice" => "required"})["tool_choice"] ==
               %{"type" => "any"}
    end

    test "\"none\" maps to none" do
      assert anthropic_tool_choice(%{"tool_choice" => "none"})["tool_choice"] ==
               %{"type" => "none"}
    end

    test "the OpenAI function form maps to a named tool" do
      choice = %{"type" => "function", "function" => %{"name" => "read_file"}}

      assert anthropic_tool_choice(%{"tool_choice" => choice})["tool_choice"] ==
               %{"type" => "tool", "name" => "read_file"}
    end

    test "parallel_tool_calls false becomes disable_parallel_tool_use" do
      body =
        anthropic_tool_choice(%{"tool_choice" => "auto", "parallel_tool_calls" => false})

      assert body["tool_choice"] == %{"type" => "auto", "disable_parallel_tool_use" => true}
    end

    test "absent tool_choice stays absent" do
      refute Map.has_key?(anthropic_tool_choice(%{}), "tool_choice")
    end
  end

  describe "structured outputs (build_anthropic_request/2)" do
    test "OpenAI response_format maps to Anthropic output_config.format" do
      schema = %{"type" => "object", "properties" => %{"severity" => %{"type" => "string"}}}

      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "response", "schema" => schema}
        }
      }

      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "claude-sonnet-5"})

      assert body["output_config"]["format"] == %{"type" => "json_schema", "schema" => schema}
    end

    test "a client reasoning_effort becomes output_config.effort" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "reasoning_effort" => "xhigh"
      }

      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "claude-sonnet-5"})

      assert body["output_config"]["effort"] == "xhigh"
    end

    test "format and effort share one output_config" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "reasoning_effort" => "low",
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "r", "schema" => %{"type" => "object"}}
        }
      }

      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "claude-sonnet-5"})

      assert body["output_config"]["effort"] == "low"
      assert body["output_config"]["format"]["type"] == "json_schema"
    end

    test "no output_config when the client asked for neither" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "claude-sonnet-5"})

      refute Map.has_key?(body, "output_config")
    end
  end

  describe "build_count_tokens_request/2" do
    test "keeps only count_tokens fields and uses the step's model" do
      params = %{
        "model" => "claude-sonnet-5",
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "system" => [%{"type" => "text", "text" => "be nice"}],
        "tools" => [%{"name" => "t", "input_schema" => %{}}],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 1024},
        "stream" => true,
        "max_tokens" => 64_000,
        "metadata" => %{"user_id" => "u1"},
        "router_slug" => "fw-claude"
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_count_tokens_request(params, step)

      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["messages"] == params["messages"]
      assert body["system"] == params["system"]
      assert body["tools"] == params["tools"]
      assert body["thinking"] == params["thinking"]
      refute Map.has_key?(body, "stream")
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "metadata")
      refute Map.has_key?(body, "router_slug")
    end

    test "falls back to the client model when the step has none" do
      params = %{"model" => "claude-sonnet-5", "messages" => []}
      body = Anthropic.build_count_tokens_request(params, %RoutingStep{model: nil})
      assert body["model"] == "claude-sonnet-5"
    end

    test "keeps a client thinking.type=disabled block on models that accept it" do
      # The count must describe the request dispatch would actually send —
      # and dispatch now forwards the disable everywhere but Fable 5.
      params = %{
        "model" => "claude-sonnet-5",
        "messages" => [],
        "thinking" => %{"type" => "disabled"}
      }

      body = Anthropic.build_count_tokens_request(params, %RoutingStep{model: "claude-sonnet-5"})
      assert body["thinking"] == %{"type" => "disabled"}
    end
  end

  describe "image content parts" do
    test "converts OpenAI image_url data URIs to Anthropic base64 image blocks" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "what is this?"},
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/jpeg;base64,/9j/4AAQ"}
              }
            ]
          }
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      [msg] = body["messages"]

      assert msg["content"] == [
               %{"type" => "text", "text" => "what is this?"},
               %{
                 "type" => "image",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "image/jpeg",
                   "data" => "/9j/4AAQ"
                 }
               }
             ]
    end

    test "converts http(s) image_url parts to Anthropic url-source image blocks" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/cat.png"}}
            ]
          }
        ]
      }

      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "m"})
      [msg] = body["messages"]

      assert msg["content"] == [
               %{
                 "type" => "image",
                 "source" => %{"type" => "url", "url" => "https://example.com/cat.png"}
               }
             ]
    end

    test "cache_control still lands on the last block of normalized part lists" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "cache_control" => %{"type" => "ephemeral"},
            "content" => [
              %{"type" => "text", "text" => "hi"},
              %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}}
            ]
          }
        ]
      }

      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "m"})
      [msg] = body["messages"]
      last = List.last(msg["content"])

      assert last["type"] == "image"
      assert last["cache_control"] == %{"type" => "ephemeral"}
    end

    test "already-native Anthropic blocks pass through unchanged" do
      native = %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "AAAA"}
      }

      request = %{"messages" => [%{"role" => "user", "content" => [native]}]}
      body = Anthropic.build_anthropic_request(request, %RoutingStep{model: "m"})
      [msg] = body["messages"]

      assert msg["content"] == [native]
    end
  end

  describe "client thinking.type=disabled (dodo_router-cit)" do
    # Probed live 2026-08-16 with a subscription token presenting as Claude
    # Code: Opus 5 / Sonnet 5 / Opus 4.8 all accept an explicit disable, and on
    # the Claude 5 models omission turns thinking ON (adaptive default) — the
    # very thing the client turned off. Only Fable 5 rejects disabled outright
    # at any effort, so only there is omission the honest spelling.
    @disabled %{"type" => "disabled"}

    defp disabled_request do
      %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "thinking" => @disabled
      }
    end

    test "forwarded verbatim on models that accept it" do
      for model <- ["claude-opus-5", "claude-sonnet-5", "claude-opus-4-8-20260115"] do
        body =
          Anthropic.build_anthropic_request(disabled_request(), %RoutingStep{model: model})

        assert body["thinking"] == @disabled, "expected disabled forwarded on #{model}"
      end
    end

    test "still not overridden by the step's reasoning_effort default" do
      body =
        Anthropic.build_anthropic_request(disabled_request(), %RoutingStep{
          model: "claude-opus-5",
          reasoning_effort: "high"
        })

      assert body["thinking"] == @disabled
      refute get_in(body, ["output_config", "effort"])
    end

    test "omitted on Fable 5, with the drop recorded rather than silent" do
      DodoRouter.Proxy.Fidelity.reset()

      body =
        Anthropic.build_anthropic_request(disabled_request(), %RoutingStep{
          model: "claude-fable-5"
        })

      refute Map.has_key?(body, "thinking")

      assert [change] = DodoRouter.Proxy.Fidelity.take().changes
      assert change["name"] == "thinking"
      assert change["action"] == "dropped"
    end

    test "count_tokens mirrors the request-path translation per model" do
      params = %{"messages" => [], "thinking" => @disabled}

      kept =
        Anthropic.build_count_tokens_request(params, %RoutingStep{model: "claude-opus-5"})

      assert kept["thinking"] == @disabled

      dropped =
        Anthropic.build_count_tokens_request(params, %RoutingStep{model: "claude-fable-5"})

      refute Map.has_key?(dropped, "thinking")
    end
  end

  describe "streaming passthrough (Anthropic client on an Anthropic step)" do
    # The native stream a thinking-enabled Claude model actually sends:
    # thinking block first (with its signature), then text. Reframing loses
    # both the thinking block and its position; passthrough must preserve
    # them byte-for-byte or the client cannot echo them back to continue.
    @native_events [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_01real",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-fable-5",
          "content" => [],
          "usage" => %{"input_tokens" => 12, "cache_read_input_tokens" => 4}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "pondering"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig_abc123"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 9}
      },
      %{"type" => "message_stop"}
    ]

    defp decode_wire(wire_chunks) do
      Enum.map(wire_chunks, fn chunk ->
        assert [_, type, json] = Regex.run(~r/\Aevent: (\S+)\ndata: (.*)\n\n\z/s, chunk)
        {type, Jason.decode!(json)}
      end)
    end

    test "every native event is relayed verbatim, in order" do
      {_acc, wire} =
        Anthropic.passthrough_anthropic_events(Anthropic.initial_stream_acc(), @native_events)

      decoded = decode_wire(wire)

      assert Enum.map(decoded, &elem(&1, 0)) == Enum.map(@native_events, & &1["type"])
      assert Enum.map(decoded, &elem(&1, 1)) == @native_events
    end

    test "the thinking block and its signature survive intact, before the text block" do
      {_acc, wire} =
        Anthropic.passthrough_anthropic_events(Anthropic.initial_stream_acc(), @native_events)

      decoded = decode_wire(wire)

      thinking_start =
        Enum.find_index(decoded, fn {_t, e} ->
          e["type"] == "content_block_start" and e["content_block"]["type"] == "thinking"
        end)

      text_start =
        Enum.find_index(decoded, fn {_t, e} ->
          e["type"] == "content_block_start" and e["content_block"]["type"] == "text"
        end)

      assert thinking_start < text_start

      assert {_, %{"delta" => %{"signature" => "sig_abc123"}}} =
               Enum.find(decoded, fn {_t, e} -> e["delta"]["type"] == "signature_delta" end)
    end

    test "no [DONE] sentinel — message_stop is the native terminator" do
      {_acc, wire} =
        Anthropic.passthrough_anthropic_events(Anthropic.initial_stream_acc(), @native_events)

      refute Enum.any?(wire, &String.contains?(&1, "[DONE]"))
      assert List.last(wire) =~ "message_stop"
    end

    test "accumulation for logging still happens: id, text, usage" do
      {acc, _wire} =
        Anthropic.passthrough_anthropic_events(Anthropic.initial_stream_acc(), @native_events)

      assert acc.message_id == "msg_01real"
      assert acc.content == "Hello"
      assert acc.stop_reason == "end_turn"
      assert acc.usage["completion_tokens"] == 9
      # input tokens arrive on message_start, not message_delta — losing them
      # is how a streamed row ends up with null prompt tokens.
      assert acc.usage["prompt_tokens"] == 12
      assert acc.usage["cache_read_tokens"] == 4
    end

    test "redacted_thinking and server-tool blocks are relayed too" do
      events = [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "redacted_thinking", "data" => "opaque"}
        },
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{
            "type" => "server_tool_use",
            "id" => "srvtoolu_01",
            "name" => "web_search"
          }
        }
      ]

      {_acc, wire} =
        Anthropic.passthrough_anthropic_events(Anthropic.initial_stream_acc(), events)

      decoded = decode_wire(wire)
      assert Enum.map(decoded, &elem(&1, 1)) == events
    end
  end

  describe "parse_anthropic_sse/2" do
    test "a message_delta sharing a frame with message_stop is not discarded" do
      data =
        "data: " <>
          Jason.encode!(%{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 7}
          }) <>
          "\n\ndata: " <> Jason.encode!(%{"type" => "message_stop"}) <> "\n\n"

      assert {{:events_then_done, events}, ""} = Anthropic.parse_anthropic_sse(data, "")
      assert Enum.map(events, & &1["type"]) == ["message_delta", "message_stop"]
    end

    test "message_stop alone still terminates" do
      data = "data: " <> Jason.encode!(%{"type" => "message_stop"}) <> "\n\n"

      assert {{:events_then_done, [%{"type" => "message_stop"}]}, ""} =
               Anthropic.parse_anthropic_sse(data, "")
    end
  end
end
