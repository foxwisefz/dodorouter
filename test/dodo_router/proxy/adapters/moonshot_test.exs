defmodule DodoRouter.Proxy.Adapters.MoonshotTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Moonshot
  alias DodoRouter.Routers.RoutingStep

  describe "build_request_body/2" do
    test "adds reasoning_content to all assistant messages when thinking enabled" do
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

      # All assistant messages should have reasoning_content
      assistant_messages = Enum.filter(body["messages"], &(&1["role"] == "assistant"))

      assert length(assistant_messages) == 3

      Enum.each(assistant_messages, fn msg ->
        assert Map.has_key?(msg, "reasoning_content"),
               "Assistant message missing reasoning_content: #{inspect(msg)}"
      end)
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
      assert assistant_msg["reasoning_content"] == ""
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

      Enum.with_index(assistant_messages, fn msg, idx ->
        assert Map.has_key?(msg, "reasoning_content"),
               "Assistant message at index #{idx} missing reasoning_content: #{inspect(msg)}"
      end)
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

    test "adds reasoning_content for kimi-k2.6 assistant messages" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there"}
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
end
