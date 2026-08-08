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

  describe "convert_sse_chunk/2 (stateful, tool calls)" do
    defp openai_chunk(delta) do
      "data: " <>
        Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => delta}]}) <> "\n\n"
    end

    defp convert_all(chunks) do
      Enum.reduce(chunks, {[], AnthropicFormat.new_sse_state()}, fn chunk, {events, state} ->
        {new_events, state} = AnthropicFormat.convert_sse_chunk(chunk, state)
        {events ++ new_events, state}
      end)
    end

    defp parse_events(events) do
      Enum.map(events, fn event ->
        [_, data] = Regex.run(~r/data: (.*)\n\n/s, event)
        Jason.decode!(data)
      end)
    end

    test "opens a tool_use content block when a tool_calls delta carries id and name" do
      chunks = [
        openai_chunk(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "toolu_01",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => ""}
            }
          ]
        }),
        openai_chunk(%{
          "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"path\":\"/tmp\"}"}}]
        })
      ]

      {events, state} = convert_all(chunks)
      parsed = parse_events(events)

      # The open text block (index 0) is closed before the tool block starts
      assert %{"type" => "content_block_stop", "index" => 0} =
               Enum.find(parsed, &(&1["type"] == "content_block_stop"))

      start_event = Enum.find(parsed, &(&1["type"] == "content_block_start"))
      assert start_event["index"] == 1
      assert start_event["content_block"]["type"] == "tool_use"
      assert start_event["content_block"]["id"] == "toolu_01"
      assert start_event["content_block"]["name"] == "read_file"

      json_deltas =
        parsed
        |> Enum.filter(&(get_in(&1, ["delta", "type"]) == "input_json_delta"))

      assert [%{"index" => 1} = json_delta] = json_deltas
      assert json_delta["delta"]["partial_json"] == "{\"path\":\"/tmp\"}"

      assert state.open_block == 1
    end

    test "opens a new block per tool call index" do
      chunks = [
        openai_chunk(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "toolu_a",
              "function" => %{"name" => "read", "arguments" => "{}"}
            }
          ]
        }),
        openai_chunk(%{
          "tool_calls" => [
            %{
              "index" => 1,
              "id" => "toolu_b",
              "function" => %{"name" => "write", "arguments" => "{}"}
            }
          ]
        })
      ]

      {events, state} = convert_all(chunks)
      parsed = parse_events(events)

      starts = Enum.filter(parsed, &(&1["type"] == "content_block_start"))
      assert [%{"index" => 1}, %{"index" => 2}] = starts

      stops = Enum.filter(parsed, &(&1["type"] == "content_block_stop"))
      assert [%{"index" => 0}, %{"index" => 1}] = stops

      assert state.open_block == 2
    end

    test "text deltas still convert and leave the text block open" do
      {events, state} = convert_all([openai_chunk(%{"content" => "Hello"})])
      parsed = parse_events(events)

      assert [%{"type" => "content_block_delta", "index" => 0}] = parsed
      assert state.open_block == 0
    end

    test "adapter tool_call chunks round-trip to Anthropic tool_use events (seam)" do
      anthropic_events = [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_01",
            "name" => "read_file",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "\"/tmp\"}"}
        }
      ]

      acc = DodoRouter.Proxy.Adapters.Anthropic.initial_stream_acc()

      {_acc, openai_chunks} =
        DodoRouter.Proxy.Adapters.Anthropic.process_anthropic_events(acc, anthropic_events)

      {events, state} = convert_all(openai_chunks)
      parsed = parse_events(events)

      start_event = Enum.find(parsed, &(&1["type"] == "content_block_start"))
      assert start_event["content_block"]["id"] == "toolu_01"
      assert start_event["content_block"]["name"] == "read_file"

      reassembled_json =
        parsed
        |> Enum.filter(&(get_in(&1, ["delta", "type"]) == "input_json_delta"))
        |> Enum.map(&get_in(&1, ["delta", "partial_json"]))
        |> Enum.join()

      assert Jason.decode!(reassembled_json) == %{"path" => "/tmp"}
      assert state.open_block == 1
    end
  end

  describe "cache_control position preservation (to_openai_params/1)" do
    test "multi-block user content keeps per-block cache_control as parts" do
      anthropic = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "text",
                "text" => "STABLE TRANSCRIPT",
                "cache_control" => %{"type" => "ephemeral"}
              },
              %{"type" => "text", "text" => "VOLATILE QUESTION"}
            ]
          }
        ]
      }

      [msg] = AnthropicFormat.to_openai_params(anthropic)["messages"]

      assert msg["content"] == [
               %{
                 "type" => "text",
                 "text" => "STABLE TRANSCRIPT",
                 "cache_control" => %{"type" => "ephemeral"}
               },
               %{"type" => "text", "text" => "VOLATILE QUESTION"}
             ]

      refute Map.has_key?(msg, "cache_control")
    end

    test "single text block stays a string with message-level cache_control" do
      anthropic = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "hello", "cache_control" => %{"type" => "ephemeral"}}
            ]
          }
        ]
      }

      [msg] = AnthropicFormat.to_openai_params(anthropic)["messages"]
      assert msg["content"] == "hello"
      assert msg["cache_control"] == %{"type" => "ephemeral"}
    end

    test "multi-block system keeps per-block cache_control and block boundaries" do
      anthropic = %{
        "system" => [
          %{"type" => "text", "text" => "IDENTITY"},
          %{
            "type" => "text",
            "text" => "BIG STABLE PROMPT",
            "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
          },
          %{"type" => "text", "text" => "VOLATILE ENV INFO"}
        ],
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      [sys_msg | _] = AnthropicFormat.to_openai_params(anthropic)["messages"]

      assert sys_msg["role"] == "system"

      assert sys_msg["content"] == [
               %{"type" => "text", "text" => "IDENTITY"},
               %{
                 "type" => "text",
                 "text" => "BIG STABLE PROMPT",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               },
               %{"type" => "text", "text" => "VOLATILE ENV INFO"}
             ]
    end

    test "single-block system stays a string" do
      anthropic = %{
        "system" => [%{"type" => "text", "text" => "just one block"}],
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      [sys_msg | _] = AnthropicFormat.to_openai_params(anthropic)["messages"]
      assert sys_msg["content"] == "just one block"
    end

    test "forwards the thinking config" do
      anthropic = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 8000}
      }

      result = AnthropicFormat.to_openai_params(anthropic)
      assert result["thinking"] == %{"type" => "enabled", "budget_tokens" => 8000}
    end
  end

  describe "seam: cache breakpoints survive the full request round-trip" do
    alias DodoRouter.Proxy.Adapters.Anthropic, as: AnthropicAdapter
    alias DodoRouter.Routers.RoutingStep, as: Step

    test "a breakpoint on a non-final block stays on that block" do
      anthropic_request = %{
        "model" => "claude-sonnet-5",
        "max_tokens" => 100,
        "system" => [
          %{"type" => "text", "text" => "IDENTITY"},
          %{
            "type" => "text",
            "text" => "BIG STABLE PROMPT",
            "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
          },
          %{"type" => "text", "text" => "VOLATILE ENV INFO"}
        ],
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "text",
                "text" => "STABLE TRANSCRIPT",
                "cache_control" => %{"type" => "ephemeral"}
              },
              %{"type" => "text", "text" => "VOLATILE QUESTION"}
            ]
          }
        ],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 8000}
      }

      body =
        anthropic_request
        |> AnthropicFormat.to_openai_params()
        |> AnthropicAdapter.build_anthropic_request(%Step{model: "claude-sonnet-5"})

      # system: three blocks, breakpoint still on the middle one
      assert [id_block, stable_block, env_block] = body["system"]
      assert id_block["text"] == "IDENTITY"
      refute Map.has_key?(id_block, "cache_control")
      assert stable_block["text"] == "BIG STABLE PROMPT"
      assert stable_block["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
      assert env_block["text"] == "VOLATILE ENV INFO"
      refute Map.has_key?(env_block, "cache_control")

      # user message: breakpoint on the transcript block, not the question
      [msg] = body["messages"]
      assert [transcript_block, question_block] = msg["content"]
      assert transcript_block["text"] == "STABLE TRANSCRIPT"
      assert transcript_block["cache_control"] == %{"type" => "ephemeral"}
      assert question_block["text"] == "VOLATILE QUESTION"
      refute Map.has_key?(question_block, "cache_control")

      # client thinking config survives
      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 8000}
    end

    test "representation does not depend on cache_control placement" do
      # Claude Code moves breakpoints between turns; the rendered content
      # bytes must not change when only cache_control moves, or the cache
      # busts at this message.
      blocks_with_cc = [
        %{"type" => "text", "text" => "part one", "cache_control" => %{"type" => "ephemeral"}},
        %{"type" => "text", "text" => "part two"}
      ]

      blocks_without_cc = [
        %{"type" => "text", "text" => "part one"},
        %{"type" => "text", "text" => "part two"}
      ]

      convert = fn blocks ->
        %{"messages" => [%{"role" => "user", "content" => blocks}]}
        |> AnthropicFormat.to_openai_params()
        |> AnthropicAdapter.build_anthropic_request(%Step{model: "m"})
        |> get_in(["messages", Access.at(0), "content"])
        |> Enum.map(&Map.delete(&1, "cache_control"))
      end

      assert convert.(blocks_with_cc) == convert.(blocks_without_cc)
    end
  end

  describe "image passthrough (to_openai_params/1)" do
    @png_block %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "iVBORw0KGgo="}
    }

    test "user message with text and image blocks becomes OpenAI content parts" do
      anthropic = %{
        "model" => "claude-sonnet-5",
        "max_tokens" => 100,
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "what is in this image?"},
              @png_block
            ]
          }
        ]
      }

      [msg] = AnthropicFormat.to_openai_params(anthropic)["messages"]

      assert msg["role"] == "user"

      assert msg["content"] == [
               %{"type" => "text", "text" => "what is in this image?"},
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "data:image/png;base64,iVBORw0KGgo="}
               }
             ]
    end

    test "url-source image blocks pass the URL through" do
      anthropic = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "image", "source" => %{"type" => "url", "url" => "https://x/y.png"}}
            ]
          }
        ]
      }

      [msg] = AnthropicFormat.to_openai_params(anthropic)["messages"]

      assert msg["content"] == [
               %{"type" => "image_url", "image_url" => %{"url" => "https://x/y.png"}}
             ]
    end

    test "multiple text blocks stay separate parts (block boundaries preserved)" do
      anthropic = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "one"},
              %{"type" => "text", "text" => "two"}
            ]
          }
        ]
      }

      [msg] = AnthropicFormat.to_openai_params(anthropic)["messages"]

      assert msg["content"] == [
               %{"type" => "text", "text" => "one"},
               %{"type" => "text", "text" => "two"}
             ]
    end

    test "images inside tool_result content surface as a user message after the tool message" do
      anthropic = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_1",
                "content" => [%{"type" => "text", "text" => "screenshot taken"}, @png_block]
              }
            ]
          }
        ]
      }

      [tool_msg, image_msg] = AnthropicFormat.to_openai_params(anthropic)["messages"]

      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == "toolu_1"
      assert tool_msg["content"] == "screenshot taken"

      assert image_msg["role"] == "user"

      assert image_msg["content"] == [
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "data:image/png;base64,iVBORw0KGgo="}
               }
             ]
    end
  end

  describe "seam: image blocks -> to_openai_params -> build_anthropic_request" do
    test "images survive the full request round-trip, tool_result images in the same user turn" do
      alias DodoRouter.Proxy.Adapters.Anthropic
      alias DodoRouter.Routers.RoutingStep

      anthropic_request = %{
        "model" => "claude-sonnet-5",
        "max_tokens" => 100,
        "messages" => [
          %{"role" => "user", "content" => "take a screenshot"},
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "toolu_1", "name" => "screenshot", "input" => %{}}
            ]
          },
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_1",
                "content" => [
                  %{"type" => "text", "text" => "done"},
                  %{
                    "type" => "image",
                    "source" => %{
                      "type" => "base64",
                      "media_type" => "image/png",
                      "data" => "iVBORw0KGgo="
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      body =
        anthropic_request
        |> AnthropicFormat.to_openai_params()
        |> Anthropic.build_anthropic_request(%RoutingStep{model: "claude-sonnet-4-20250514"})

      # the tool_result and the surfaced image must land in the same user turn
      tool_turn =
        Enum.find(body["messages"], fn m ->
          is_list(m["content"]) and Enum.any?(m["content"], &(&1["type"] == "tool_result"))
        end)

      assert tool_turn["role"] == "user"

      image_block = Enum.find(tool_turn["content"], &(&1["type"] == "image"))
      assert image_block["source"]["type"] == "base64"
      assert image_block["source"]["media_type"] == "image/png"
      assert image_block["source"]["data"] == "iVBORw0KGgo="
    end
  end

  describe "unknown_fields/1" do
    @known %{
      "model" => "claude-sonnet-5",
      "messages" => [%{"role" => "user", "content" => "hi"}],
      "max_tokens" => 1024
    }

    test "returns [] when every field is consumed by the conversion" do
      params =
        Map.merge(@known, %{
          "system" => [%{"type" => "text", "text" => "be nice"}],
          "stream" => true,
          "temperature" => 1,
          "top_p" => 0.9,
          "stop_sequences" => ["</done>"],
          "thinking" => %{"type" => "enabled", "budget_tokens" => 1024},
          "tools" => []
        })

      assert AnthropicFormat.unknown_fields(params) == []
    end

    test "flags a field the converter silently drops (output_config)" do
      # Anthropic structured outputs: the client constrains decoding with a
      # schema, we drop it, the model answers in prose, the client's parse
      # fails. This detector is how we learn about such fields on day one.
      params = Map.put(@known, "output_config", %{"format" => %{"type" => "json_schema"}})

      assert AnthropicFormat.unknown_fields(params) == ["output_config"]
    end

    test "ignores router_slug, which Phoenix injects from the path" do
      params = Map.put(@known, "router_slug", "fw-claude")

      assert AnthropicFormat.unknown_fields(params) == []
    end

    test "reports every unconsumed field, sorted" do
      params =
        Map.merge(@known, %{
          "router_slug" => "fw-claude",
          "top_k" => 40,
          "metadata" => %{"user_id" => "u1"},
          "context_management" => %{"edits" => []}
        })

      assert AnthropicFormat.unknown_fields(params) == [
               "context_management",
               "metadata",
               "top_k"
             ]
    end

    test "flags tool_choice, which the converter does not currently carry" do
      params = Map.put(@known, "tool_choice", %{"type" => "any"})

      assert AnthropicFormat.unknown_fields(params) == ["tool_choice"]
    end
  end
end
