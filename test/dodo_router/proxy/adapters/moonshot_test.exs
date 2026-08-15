defmodule DodoRouter.Proxy.Adapters.MoonshotTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Moonshot
  alias DodoRouter.Routers.RoutingStep

  describe "build_request_body/2" do
    test "adds reasoning_content to assistant messages with tool_calls when thinking enabled" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there"},
          %{"role" => "user", "content" => "Use a tool"},
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [%{"id" => "call_1", "function" => %{"name" => "test"}}]
          },
          %{"role" => "tool", "content" => "result", "tool_call_id" => "call_1"},
          %{"role" => "assistant", "content" => "Done"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assistant_messages = Enum.filter(body["messages"], &(&1["role"] == "assistant"))
      assert length(assistant_messages) == 3

      # Only assistant messages with tool_calls get reasoning_content
      tool_call_msg = Enum.find(assistant_messages, &Map.has_key?(&1, "tool_calls"))
      assert tool_call_msg["reasoning_content"] == " "
    end

    test "adds reasoning_content to assistant messages with tool_calls" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Use a tool"},
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "call_123",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => "{}"}
              }
            ]
          },
          %{"role" => "tool", "content" => "file contents", "tool_call_id" => "call_123"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        # Default - should still enable thinking
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert assistant_msg["reasoning_content"] == " "
    end

    test "converts reasoning_details to reasoning_content" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Think about this"},
          %{
            "role" => "assistant",
            "content" => "Here's my answer",
            "reasoning_details" => [
              %{"type" => "reasoning.text", "text" => "Let me think..."},
              %{"type" => "reasoning.text", "text" => " and consider..."}
            ]
          }
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))

      # reasoning_details should be converted to reasoning_content
      assert assistant_msg["reasoning_content"] == "Let me think... and consider..."
      refute Map.has_key?(assistant_msg, "reasoning_details")
    end

    test "does NOT add reasoning_content when thinking explicitly disabled" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: false
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(assistant_msg, "reasoning_content")
    end

    test "strips client temperature for kimi-k2.5 (fixed-temperature model)" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.4
      }

      step = %RoutingStep{provider: "moonshot", model: "kimi-k2.5"}

      body = Moonshot.build_request_body(request, step)

      refute Map.has_key?(body, "temperature")
    end

    test "strips client temperature for kimi-k2.6 (fixed-temperature model)" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.4
      }

      step = %RoutingStep{provider: "moonshot", model: "kimi-k2.6", reasoning_effort: "minimal"}

      body = Moonshot.build_request_body(request, step)

      refute Map.has_key?(body, "temperature")
    end

    test "strips client temperature for kimi-for-coding" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.6
      }

      step = %RoutingStep{provider: "moonshot", model: "kimi-for-coding", plan_type: "coding"}

      body = Moonshot.build_request_body(request, step)

      refute Map.has_key?(body, "temperature")
    end

    test "strips step default temperature for fixed-temperature models" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{provider: "moonshot", model: "kimi-k2.5", temperature: 0.7}

      body = Moonshot.build_request_body(request, step)

      refute Map.has_key?(body, "temperature")
    end

    test "still clamps temperature for models that accept it" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 1.5
      }

      step = %RoutingStep{provider: "moonshot", model: "kimi-k2"}

      body = Moonshot.build_request_body(request, step)

      assert body["temperature"] == 1.0
    end

    test "passes through in-range temperature for moonshot-v1 models" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.4
      }

      step = %RoutingStep{provider: "moonshot", model: "moonshot-v1-8k"}

      body = Moonshot.build_request_body(request, step)

      assert body["temperature"] == 0.4
    end

    test "sets thinking type to enabled by default for kimi-k2.5" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      assert body["thinking"] == %{"type" => "enabled"}
    end

    test "sets thinking type to disabled when explicitly false" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: false
      }

      body = Moonshot.build_request_body(request, step)

      assert body["thinking"] == %{"type" => "disabled"}
    end

    test "handles long conversation with multiple tool calls" do
      # Simulates a real conversation with many messages
      messages = [
        %{"role" => "user", "content" => "Start task"},
        %{
          "role" => "assistant",
          "content" => "I'll help",
          "tool_calls" => [%{"id" => "c1", "function" => %{"name" => "t1"}}]
        },
        %{"role" => "tool", "content" => "r1", "tool_call_id" => "c1"},
        %{
          "role" => "assistant",
          "content" => "Next step",
          "tool_calls" => [%{"id" => "c2", "function" => %{"name" => "t2"}}]
        },
        %{"role" => "tool", "content" => "r2", "tool_call_id" => "c2"},
        %{
          "role" => "assistant",
          "content" => "More work",
          "tool_calls" => [%{"id" => "c3", "function" => %{"name" => "t3"}}]
        },
        %{"role" => "tool", "content" => "r3", "tool_call_id" => "c3"},
        %{"role" => "assistant", "content" => "Done"}
      ]

      request = %{"messages" => messages}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      # Every assistant message must have reasoning_content
      assistant_messages = Enum.filter(body["messages"], &(&1["role"] == "assistant"))

      assert length(assistant_messages) == 4

      # Assistant messages with tool_calls must have reasoning_content
      tool_call_msgs = Enum.filter(assistant_messages, &Map.has_key?(&1, "tool_calls"))

      Enum.each(tool_call_msgs, fn msg ->
        assert Map.has_key?(msg, "reasoning_content"),
               "Tool-call assistant message missing reasoning_content: #{inspect(msg)}"
      end)
    end

    test "replaces nil reasoning_content with empty string" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [%{"id" => "call_1", "function" => %{"name" => "test"}}],
            "reasoning_content" => nil
          },
          %{"role" => "tool", "content" => "result", "tool_call_id" => "call_1"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert assistant_msg["reasoning_content"] == " "
    end

    test "preserves existing reasoning_content" do
      IO.inspect("test 178")

      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{
            "role" => "assistant",
            "content" => "Hi",
            "reasoning_content" => "I thought about greeting options"
          }
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert assistant_msg["reasoning_content"] == "I thought about greeting options"
    end

    test "enables thinking for kimi-k2.6 by default" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      assert body["thinking"] == %{"type" => "enabled"}
    end

    test "enables thinking for kimi-k2 by default" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2",
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      assert body["thinking"] == %{"type" => "enabled"}
    end

    test "enables thinking for kimi-for-coding by default" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-for-coding",
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      assert body["thinking"] == %{"type" => "enabled"}
      assert body["model"] == "kimi-for-coding"
    end

    test "adds reasoning_content for kimi-k2.6 assistant messages with tool_calls" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{
            "role" => "assistant",
            "content" => "Hi there",
            "tool_calls" => [%{"id" => "c1", "function" => %{"name" => "t1"}}]
          }
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert Map.has_key?(assistant_msg, "reasoning_content")
    end

    test "disables thinking for kimi-k2.6 when explicitly false" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hi"},
          %{"role" => "assistant", "content" => "Hey"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: false
      }

      body = Moonshot.build_request_body(request, step)

      assert body["thinking"] == %{"type" => "disabled"}

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(assistant_msg, "reasoning_content")
    end

    test "does not add thinking for moonshot-v1 models" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "moonshot-v1-8k",
        thinking_enabled: nil
      }

      body = Moonshot.build_request_body(request, step)

      refute Map.has_key?(body, "thinking")
    end

    test "uses reasoning_effort to disable thinking on kimi-k2" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        reasoning_effort: "none"
      }

      body = Moonshot.build_request_body(request, step)
      assert body["thinking"] == %{"type" => "disabled"}
    end

    test "uses reasoning_effort to enable thinking on kimi-k2" do
      request = %{"messages" => [%{"role" => "user", "content" => "Hi"}]}

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.5",
        reasoning_effort: "high"
      }

      body = Moonshot.build_request_body(request, step)
      assert body["thinking"] == %{"type" => "enabled"}
    end

    test "normalizes tool_call arguments from object to JSON string" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Write a file"},
          %{
            "role" => "assistant",
            "content" => "I'll write it",
            "tool_calls" => [
              %{
                "id" => "Write:15",
                "type" => "function",
                "function" => %{
                  "name" => "Write",
                  "arguments" => %{"file_path" => "/tmp/test.txt", "content" => "hello"}
                }
              }
            ]
          },
          %{"role" => "tool", "content" => "done", "tool_call_id" => "Write:15"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      args = assistant_msg["tool_calls"] |> Enum.at(0) |> get_in(["function", "arguments"])
      assert is_binary(args)
      assert Jason.decode!(args) == %{"file_path" => "/tmp/test.txt", "content" => "hello"}
    end

    test "handles tool_calls with already-string arguments" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "test", "arguments" => "{\"key\":\"val\"}"}
              }
            ]
          },
          %{"role" => "tool", "content" => "ok", "tool_call_id" => "call_1"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assistant_msg = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      args = assistant_msg["tool_calls"] |> Enum.at(0) |> get_in(["function", "arguments"])
      assert args == "{\"key\":\"val\"}"
    end
  end

  describe "base_url and endpoint routing" do
    test "returns coding URL for coding plan_type" do
      step = %RoutingStep{plan_type: "coding"}
      assert Moonshot.base_url(step) == "https://api.kimi.com/coding/v1"
    end

    test "returns standard URL for standard plan_type" do
      step = %RoutingStep{plan_type: "standard"}
      assert Moonshot.base_url(step) == "https://api.moonshot.ai/v1"
    end

    test "returns standard URL for nil plan_type" do
      step = %RoutingStep{plan_type: nil}
      assert Moonshot.base_url(step) == "https://api.moonshot.ai/v1"
    end

    test "filters out non-function tools for Moonshot" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "exec_command",
              "description" => "Run a command"
            }
          },
          %{
            "type" => "web_search",
            "external_web_access" => false
          },
          %{
            "type" => "image_generation",
            "output_format" => "png"
          },
          %{
            "type" => "function",
            "function" => %{
              "name" => "view_image",
              "description" => "View an image"
            }
          }
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      assert length(body["tools"]) == 2

      tool_names = Enum.map(body["tools"], &get_in(&1, ["function", "name"]))
      assert "exec_command" in tool_names
      assert "view_image" in tool_names
      refute Enum.any?(body["tools"], &(&1["type"] != "function"))
    end

    test "removes tools key entirely when only non-function tools present" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => [
          %{"type" => "web_search", "external_web_access" => false},
          %{"type" => "image_generation", "output_format" => "png"}
        ]
      }

      step = %RoutingStep{
        provider: "moonshot",
        model: "kimi-k2.6",
        thinking_enabled: true
      }

      body = Moonshot.build_request_body(request, step)

      refute Map.has_key?(body, "tools")
    end

    test "does not include stream_options in build_request_body" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "kimi-k2", provider: "moonshot"}

      body = Moonshot.build_request_body(request, step)
      refute Map.has_key?(body, "stream_options")
    end
  end

  describe "accumulate_tool_calls/2" do
    test "accumulates tool call chunks by index" do
      existing = %{}

      chunk1 = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => ""}
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
                %{
                  "index" => 0,
                  "function" => %{"arguments" => "{\"path\":"}
                }
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
                %{
                  "index" => 0,
                  "function" => %{"arguments" => "\"/tmp/test\"}"}
                }
              ]
            }
          }
        ]
      }

      acc1 = Moonshot.accumulate_tool_calls(existing, chunk1)
      acc2 = Moonshot.accumulate_tool_calls(acc1, chunk2)
      acc3 = Moonshot.accumulate_tool_calls(acc2, chunk3)

      assert acc3[0]["id"] == "call_abc"
      assert acc3[0]["function"]["name"] == "read_file"
      assert acc3[0]["function"]["arguments"] == "{\"path\":\"/tmp/test\"}"
    end

    test "handles multiple concurrent tool calls" do
      existing = %{}

      # Two tool calls in same chunk
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "function" => %{"name" => "tool_a", "arguments" => "{}"}
                },
                %{
                  "index" => 1,
                  "id" => "call_2",
                  "function" => %{"name" => "tool_b", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      }

      result = Moonshot.accumulate_tool_calls(existing, chunk)

      assert result[0]["function"]["name"] == "tool_a"
      assert result[1]["function"]["name"] == "tool_b"
    end
  end

  describe "parse_raw_error/1" do
    test "returns nil for nil" do
      assert Moonshot.parse_raw_error(nil) == nil
    end

    test "parses JSON error body from streaming error response" do
      raw =
        "{\"error\":{\"message\":\"You've reached your usage limit\",\"type\":\"access_terminated_error\"}}"

      result = Moonshot.parse_raw_error(raw)
      assert result["error"]["message"] =~ "usage limit"
    end

    test "returns raw string when not valid JSON" do
      raw = "some plain text error"
      result = Moonshot.parse_raw_error(raw)
      assert result == "some plain text error"
    end

    test "decompresses gzip data before parsing" do
      json = "{\"error\":{\"message\":\"quota exceeded\"}}"
      gzipped = :zlib.gzip(json)
      result = Moonshot.parse_raw_error(gzipped)
      assert result["error"]["message"] == "quota exceeded"
    end
  end

  describe "stream usage accumulation" do
    # Probed live 2026-08-16: without stream_options (which the coding endpoint
    # rejects, see 46a95cf), Moonshot delivers usage INSIDE the final chunk's
    # choice, not as a top-level usage frame.
    @choice_level_final_chunk %{
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => "stop",
          "usage" => %{
            "prompt_tokens" => 8,
            "completion_tokens" => 5,
            "total_tokens" => 13,
            "prompt_tokens_details" => %{"cached_tokens" => 8}
          }
        }
      ]
    }

    @timing_meta %{payload_size_bytes: 100, upload_ms: 1, provider_processing_ms: nil}

    defp fresh_acc do
      %{
        content: "",
        tool_calls: %{},
        usage: nil,
        finish_reason: nil,
        first_chunk_time: 5,
        sse_buffer: ""
      }
    end

    test "usage nested in the final chunk's choice reaches extract_usage/1" do
      acc = Moonshot.accumulate_chunk(fresh_acc(), @choice_level_final_chunk)
      response = Moonshot.build_final_response(acc, @timing_meta)
      usage = DodoRouter.Proxy.Adapter.extract_usage(response)

      assert usage.prompt_tokens == 8
      assert usage.completion_tokens == 5
      assert usage.total_tokens == 13
      assert usage.cache_read_tokens == 8
    end

    test "a top-level usage frame wins over an earlier choice-level one" do
      top_level_frame = %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 6, "total_tokens" => 15}
      }

      acc =
        fresh_acc()
        |> Moonshot.accumulate_chunk(@choice_level_final_chunk)
        |> Moonshot.accumulate_chunk(top_level_frame)

      usage =
        DodoRouter.Proxy.Adapter.extract_usage(Moonshot.build_final_response(acc, @timing_meta))

      assert usage.prompt_tokens == 9
    end

    test "content chunks without usage keep the accumulated value" do
      content_chunk = %{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "!"}, "finish_reason" => nil}]
      }

      acc =
        fresh_acc()
        |> Moonshot.accumulate_chunk(@choice_level_final_chunk)
        |> Moonshot.accumulate_chunk(content_chunk)

      usage =
        DodoRouter.Proxy.Adapter.extract_usage(Moonshot.build_final_response(acc, @timing_meta))

      assert usage.prompt_tokens == 8
    end
  end
end
