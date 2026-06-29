defmodule DodoRouter.CacheVisibilityTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.Anthropic
  alias DodoRouter.Proxy.Adapters.Google
  alias DodoRouterWeb.AnthropicFormat

  describe "extract_usage/1 — cache token capture" do
    test "extracts Anthropic cache tokens from normalized usage" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150,
          "cache_read_tokens" => 80,
          "cache_write_tokens" => 20
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.cache_read_tokens == 80
      assert usage.cache_write_tokens == 20
    end

    test "extracts OpenAI cached_tokens from prompt_tokens_details" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150,
          "prompt_tokens_details" => %{
            "cached_tokens" => 75
          }
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.cache_read_tokens == 75
      assert usage.cache_write_tokens == nil
    end

    test "extracts Anthropic native cache fields (cache_read_input_tokens)" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150,
          "cache_read_input_tokens" => 90,
          "cache_creation_input_tokens" => 10
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.cache_read_tokens == 90
      assert usage.cache_write_tokens == 10
    end

    test "returns nil cache tokens when not present" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.cache_read_tokens == nil
      assert usage.cache_write_tokens == nil
    end

    test "handles missing usage entirely" do
      usage = Adapter.extract_usage(%{})
      assert usage.cache_read_tokens == nil
      assert usage.cache_write_tokens == nil
    end

    test "extracts DeepSeek prompt_cache_hit_tokens" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150,
          "prompt_cache_hit_tokens" => 80,
          "prompt_cache_miss_tokens" => 20
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.cache_read_tokens == 80
    end

    test "extracts Groq/xAI cached_tokens via prompt_tokens_details" do
      response = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150,
          "prompt_tokens_details" => %{
            "cached_tokens" => 60
          }
        }
      }

      usage = Adapter.extract_usage(response)
      assert usage.cache_read_tokens == 60
    end
  end

  describe "Anthropic adapter — cache token preservation" do
    test "convert_to_openai_format preserves cache_read tokens" do
      anthropic_response = %{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_read_input_tokens" => 80,
          "cache_creation_input_tokens" => 20
        }
      }

      result = Anthropic.convert_to_openai_format(anthropic_response)
      assert result["usage"]["cache_read_tokens"] == 80
      assert result["usage"]["cache_write_tokens"] == 20
    end

    test "convert_to_openai_format works without cache fields" do
      anthropic_response = %{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      result = Anthropic.convert_to_openai_format(anthropic_response)
      refute Map.has_key?(result["usage"], "cache_read_tokens")
      refute Map.has_key?(result["usage"], "cache_write_tokens")
    end
  end

  describe "Google adapter — cache token preservation" do
    test "convert_to_openai_format preserves cachedContentTokenCount" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Hello!"}],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 50,
          "totalTokenCount" => 150,
          "cachedContentTokenCount" => 80
        }
      }

      result = Google.convert_to_openai_format(gemini_response)
      assert result["usage"]["cache_read_tokens"] == 80
    end

    test "convert_to_openai_format works without cachedContentTokenCount" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Hello!"}],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 50,
          "totalTokenCount" => 150
        }
      }

      result = Google.convert_to_openai_format(gemini_response)
      refute Map.has_key?(result["usage"], "cache_read_tokens")
    end
  end

  describe "AnthropicFormat — cache_control pass-through" do
    test "preserves cache_control on system message" do
      anthropic_params = %{
        "model" => "claude-sonnet-4-20250514",
        "max_tokens" => 1024,
        "system" => [
          %{
            "type" => "text",
            "text" => "You are helpful",
            "cache_control" => %{"type" => "ephemeral"}
          }
        ],
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      openai_params = AnthropicFormat.to_openai_params(anthropic_params)

      system_msg = hd(openai_params["messages"])
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful"
      assert system_msg["cache_control"] == %{"type" => "ephemeral"}
    end

    test "preserves cache_control on user message content blocks" do
      anthropic_params = %{
        "model" => "claude-sonnet-4-20250514",
        "max_tokens" => 1024,
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "text",
                "text" => "important context",
                "cache_control" => %{"type" => "ephemeral"}
              }
            ]
          }
        ]
      }

      openai_params = AnthropicFormat.to_openai_params(anthropic_params)

      user_msg = Enum.find(openai_params["messages"], &(&1["role"] == "user"))
      assert user_msg["content"] == "important context"
      assert user_msg["cache_control"] == %{"type" => "ephemeral"}
    end

    test "preserves cache_control on tools" do
      anthropic_params = %{
        "model" => "claude-sonnet-4-20250514",
        "max_tokens" => 1024,
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "tools" => [
          %{
            "name" => "read_file",
            "description" => "Read a file",
            "input_schema" => %{"type" => "object"},
            "cache_control" => %{"type" => "ephemeral"}
          }
        ]
      }

      openai_params = AnthropicFormat.to_openai_params(anthropic_params)

      tool = hd(openai_params["tools"])
      assert tool["cache_control"] == %{"type" => "ephemeral"}
    end

    test "passes cache fields back in from_openai_response" do
      openai_response = %{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "cache_read_tokens" => 80,
          "cache_write_tokens" => 20
        }
      }

      anthropic_response = AnthropicFormat.from_openai_response(openai_response)
      assert anthropic_response["usage"]["cache_read_input_tokens"] == 80
      assert anthropic_response["usage"]["cache_creation_input_tokens"] == 20
    end
  end

  describe "Anthropic adapter outbound — cache_control forwarding" do
    alias DodoRouter.Routers.RoutingStep

    test "forwards cache_control on system message" do
      request = %{
        "messages" => [
          %{
            "role" => "system",
            "content" => "You are helpful",
            "cache_control" => %{"type" => "ephemeral"}
          },
          %{"role" => "user", "content" => "hi"}
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      system_blocks = body["system"]
      assert is_list(system_blocks)
      assert hd(system_blocks)["cache_control"] == %{"type" => "ephemeral"}
    end

    test "forwards cache_control on user message" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "context", "cache_control" => %{"type" => "ephemeral"}}
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      user_msg = hd(body["messages"])
      assert user_msg["role"] == "user"
      content = user_msg["content"]
      assert is_list(content)
      last_block = List.last(content)
      assert last_block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "forwards cache_control on tools" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{"name" => "read_file", "description" => "Read", "parameters" => %{}},
            "cache_control" => %{"type" => "ephemeral"}
          }
        ]
      }

      step = %RoutingStep{model: "claude-sonnet-4-20250514"}
      body = Anthropic.build_anthropic_request(request, step)

      tool = hd(body["tools"])
      assert tool["cache_control"] == %{"type" => "ephemeral"}
    end
  end
end
