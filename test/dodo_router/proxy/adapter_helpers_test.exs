defmodule DodoRouter.Proxy.AdapterHelpersTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Providers

  describe "generate_key_hint/1" do
    test "returns empty string for nil" do
      assert Providers.generate_key_hint(nil) == ""
    end

    test "fully masks keys 1-4 chars" do
      assert Providers.generate_key_hint("a") == "•"
      assert Providers.generate_key_hint("ab") == "••"
      assert Providers.generate_key_hint("abcd") == "••••"
    end

    test "shows first 2 chars for keys 5-8 chars" do
      assert Providers.generate_key_hint("abcde") == "ab•••"
      assert Providers.generate_key_hint("sk-1234") == "sk•••••"
    end

    test "shows first 3 chars for keys 9-11 chars" do
      assert Providers.generate_key_hint("sk-abcde1") == "sk-••••••"
      assert Providers.generate_key_hint("sk-abcdefgh") == "sk-••••••••"
    end

    test "keys 12+ chars get a fixed-width hint: 3 + •••• + 3" do
      # Length-preserving masking made 60+ char keys render 50+ bullets,
      # overflowing every select and card that shows a hint.
      assert Providers.generate_key_hint("sk-abcdefg1234") == "sk-••••234"

      assert Providers.generate_key_hint("sk-proj-abc123def456ghi789xyz") == "sk-••••xyz"
    end

    test "never reveals the full API key" do
      for key <- [
            "x",
            "ab",
            "abcde",
            "sk-1234",
            "sk-abcde1",
            "sk-abcdefg1234",
            "sk-proj-abc123def456ghi789xyz"
          ] do
        hint = Providers.generate_key_hint(key)
        assert hint != key, "Hint should not equal the full key for: #{key}"
        assert String.contains?(hint, "•"), "Hint must contain at least one bullet for: #{key}"
      end
    end

    test "hint never exceeds 11 characters regardless of key length" do
      for len <- 1..200 do
        key = String.duplicate("a", len)
        hint = Providers.generate_key_hint(key)
        assert String.length(hint) <= 11
      end
    end

    test "compact_key_hint collapses bullet runs in hints stored under the old scheme" do
      long_stored = "sk-" <> String.duplicate("•", 57) <> "X2F"
      assert Providers.compact_key_hint(long_stored) == "sk-••••X2F"
      # already-short hints pass through
      assert Providers.compact_key_hint("sk-••••abc") == "sk-••••abc"
      assert Providers.compact_key_hint(nil) == ""
    end
  end

  describe "categorize_error/2" do
    test "maps status codes to error reasons" do
      assert Adapter.categorize_error(429) == :rate_limited
      assert Adapter.categorize_error(401) == :auth_error
      assert Adapter.categorize_error(403) == :auth_error
      assert Adapter.categorize_error(503) == :model_unavailable
      assert Adapter.categorize_error(500) == :server_error
      assert Adapter.categorize_error(502) == :server_error
      assert Adapter.categorize_error(418) == :unknown
    end

    test "400 with content keyword returns content_policy" do
      assert Adapter.categorize_error(400, %{
               "error" => %{"message" => "Content policy violation"}
             }) == :content_policy

      assert Adapter.categorize_error(400, %{"error" => %{"message" => "Policy blocked"}}) ==
               :content_policy
    end

    test "400 without content keyword returns bad_request" do
      assert Adapter.categorize_error(400, %{"error" => %{"message" => "Invalid request"}}) ==
               :bad_request
    end
  end

  describe "should_fallback?/1" do
    test "returns true for fallback-eligible errors" do
      assert Adapter.should_fallback?(:rate_limited) == true
      assert Adapter.should_fallback?(:server_error) == true
      assert Adapter.should_fallback?(:timeout) == true
      assert Adapter.should_fallback?(:model_unavailable) == true
      assert Adapter.should_fallback?(:auth_error) == true
      assert Adapter.should_fallback?(:unknown) == true
      assert Adapter.should_fallback?(:bad_request) == true
      assert Adapter.should_fallback?(:content_policy) == true
    end

    test "returns false for non-fallback errors" do
      assert Adapter.should_fallback?(:some_future_error) == false
    end
  end

  describe "extract_usage/1" do
    test "extracts usage from response" do
      response = %{
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
      }

      usage = Adapter.extract_usage(response)
      assert usage.prompt_tokens == 10
      assert usage.completion_tokens == 20
      assert usage.total_tokens == 30
    end

    test "returns nils when no usage" do
      usage = Adapter.extract_usage(%{})
      assert usage.prompt_tokens == nil
      assert usage.completion_tokens == nil
      assert usage.total_tokens == nil
    end
  end

  describe "detect_call_type/2" do
    test "detects tool_call when response has tool_calls" do
      request = %{"tools" => [%{"name" => "test"}]}

      response = %{
        "choices" => [%{"message" => %{"tool_calls" => [%{"function" => %{"name" => "read"}}]}}]
      }

      assert {type, tools} = Adapter.detect_call_type(request, response)
      assert type == "tool_call"
      assert tools == ["read"]
    end

    test "detects tool_enabled_completion when tools present but none used" do
      request = %{"tools" => [%{"name" => "test"}]}
      response = %{"choices" => [%{"message" => %{"content" => "hi"}}]}
      assert Adapter.detect_call_type(request, response) == {"tool_enabled_completion", []}
    end

    test "detects plain completion" do
      request = %{}
      response = %{"choices" => [%{"message" => %{"content" => "hi"}}]}
      assert Adapter.detect_call_type(request, response) == {"completion", []}
    end
  end

  describe "sanitize_request/1" do
    test "strips non-standard fields" do
      request = %{
        "model" => "gpt-4o",
        "messages" => [],
        "router_slug" => "my-router",
        "parallel_tool_calls" => true
      }

      result = Adapter.sanitize_request(request)
      assert Map.has_key?(result, "model")
      assert Map.has_key?(result, "messages")
      refute Map.has_key?(result, "router_slug")
      refute Map.has_key?(result, "parallel_tool_calls")
    end

    test "normalizes max_completion_tokens to max_tokens" do
      request = %{"messages" => [], "max_completion_tokens" => 100}
      result = Adapter.sanitize_request(request)
      assert result["max_tokens"] == 100
      refute Map.has_key?(result, "max_completion_tokens")
    end

    test "prefers max_tokens over max_completion_tokens" do
      request = %{"messages" => [], "max_tokens" => 50, "max_completion_tokens" => 100}
      result = Adapter.sanitize_request(request)
      assert result["max_tokens"] == 50
      refute Map.has_key?(result, "max_completion_tokens")
    end

    test "strips non-standard message fields" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi", "custom_field" => "removed"}
        ]
      }

      result = Adapter.sanitize_request(request)
      msg = hd(result["messages"])
      refute Map.has_key?(msg, "custom_field")
      assert msg["role"] == "user"
    end

    test "normalizes array content for tool messages" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "content" => [%{"type" => "text", "text" => "file contents"}],
            "tool_call_id" => "c1"
          }
        ]
      }

      result = Adapter.sanitize_request(request)
      msg = hd(result["messages"])
      assert msg["content"] == "file contents"
    end

    test "normalizes array content for user messages" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "hello"}, %{"text" => " world"}]
          }
        ]
      }

      result = Adapter.sanitize_request(request)
      msg = hd(result["messages"])
      assert msg["content"] == "hello\n world"
    end
  end

  describe "has_images?/1" do
    test "returns true when image_url in content" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "image_url", "image_url" => %{"url" => "http://x"}}]
          }
        ]
      }

      assert Adapter.has_images?(request) == true
    end

    test "returns true when image type in content" do
      request = %{"messages" => [%{"role" => "user", "content" => [%{"type" => "image"}]}]}
      assert Adapter.has_images?(request) == true
    end

    test "returns false for text-only content" do
      request = %{"messages" => [%{"role" => "user", "content" => "just text"}]}
      assert Adapter.has_images?(request) == false
    end
  end

  describe "has_tools?/1" do
    test "returns true when tools list non-empty" do
      assert Adapter.has_tools?(%{"tools" => [%{"name" => "test"}]}) == true
    end

    test "returns false when no tools" do
      assert Adapter.has_tools?(%{}) == false
      assert Adapter.has_tools?(%{"tools" => []}) == false
    end
  end

  describe "flatten_content_to_string/1" do
    test "flattens text-only content arrays" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
        ]
      }

      result = Adapter.flatten_content_to_string(request)
      assert hd(result["messages"])["content"] == "hello"
    end

    test "preserves arrays with images" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "look"},
              %{"type" => "image_url", "image_url" => %{"url" => "http://x"}}
            ]
          }
        ]
      }

      result = Adapter.flatten_content_to_string(request)
      assert is_list(hd(result["messages"])["content"])
    end
  end

  describe "strip_name_from_messages/2" do
    test ":all strips from all messages" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi", "name" => "A"},
          %{"role" => "tool", "content" => "r", "tool_call_id" => "c1", "name" => "B"}
        ]
      }

      result = Adapter.strip_name_from_messages(request, :all)
      for msg <- result["messages"], do: refute(Map.has_key?(msg, "name"))
    end

    test ":non_tool strips from all except tool messages" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi", "name" => "A"},
          %{"role" => "tool", "content" => "r", "tool_call_id" => "c1", "name" => "B"}
        ]
      }

      result = Adapter.strip_name_from_messages(request, :non_tool)
      user_msg = Enum.find(result["messages"], &(&1["role"] == "user"))
      tool_msg = Enum.find(result["messages"], &(&1["role"] == "tool"))
      refute Map.has_key?(user_msg, "name")
      assert Map.has_key?(tool_msg, "name")
    end
  end

  describe "filter_empty_assistant_messages/1" do
    test "removes assistant messages with empty content and no tool_calls" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{"role" => "assistant", "content" => ""},
          %{"role" => "assistant", "content" => nil},
          %{"role" => "user", "content" => "hello"}
        ]
      }

      result = Adapter.filter_empty_assistant_messages(request)
      assert length(result["messages"]) == 2
    end

    test "keeps assistant with tool_calls even if content empty" do
      request = %{
        "messages" => [
          %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "c1"}]}
        ]
      }

      result = Adapter.filter_empty_assistant_messages(request)
      assert length(result["messages"]) == 1
    end
  end

  describe "clean_tool_schemas/1" do
    test "removes $id, $schema, additionalProperties, and strict from nested schemas" do
      request = %{
        "messages" => [],
        "tools" => [
          %{
            "function" => %{
              "name" => "test",
              "strict" => true,
              "parameters" => %{
                "$id" => "test-id",
                "$schema" => "https://json-schema.org",
                "additionalProperties" => false,
                "type" => "object",
                "properties" => %{
                  "name" => %{
                    "type" => "string",
                    "$id" => "nested-id",
                    "additionalProperties" => true
                  }
                }
              }
            }
          }
        ]
      }

      result = Adapter.clean_tool_schemas(request)
      tool = hd(result["tools"])
      params = tool["function"]["parameters"]

      refute Map.has_key?(params, "$id")
      refute Map.has_key?(params, "$schema")
      refute Map.has_key?(params, "additionalProperties")
      refute Map.has_key?(tool["function"], "strict")
      refute Map.has_key?(params["properties"]["name"], "$id")
      refute Map.has_key?(params["properties"]["name"], "additionalProperties")
    end
  end

  describe "clamp_temperature/3" do
    test "clamps temperature to range" do
      request = %{"messages" => [], "temperature" => -0.5}
      result = Adapter.clamp_temperature(request, 0.0, 2.0)
      assert result["temperature"] == 0.0

      request = %{"messages" => [], "temperature" => 5.0}
      result = Adapter.clamp_temperature(request, 0.0, 2.0)
      assert result["temperature"] == 2.0
    end

    test "no-ops when temperature is in range" do
      request = %{"messages" => [], "temperature" => 1.0}
      result = Adapter.clamp_temperature(request, 0.0, 2.0)
      assert result["temperature"] == 1.0
    end

    test "no-ops when no temperature" do
      request = %{"messages" => []}
      result = Adapter.clamp_temperature(request, 0.0, 2.0)
      refute Map.has_key?(result, "temperature")
    end
  end

  describe "fix_tool_call_finish_reason/1" do
    test "sets finish_reason to tool_calls when tool_calls present but finish_reason nil" do
      response = %{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "tool_calls" => [%{"id" => "c1"}]},
            "finish_reason" => nil
          }
        ]
      }

      result = Adapter.fix_tool_call_finish_reason(response)
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"
    end

    test "sets finish_reason to tool_calls when empty string" do
      response = %{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "tool_calls" => [%{"id" => "c1"}]},
            "finish_reason" => ""
          }
        ]
      }

      result = Adapter.fix_tool_call_finish_reason(response)
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"
    end

    test "does not override non-nil finish_reason" do
      response = %{
        "choices" => [
          %{"message" => %{"tool_calls" => [%{"id" => "c1"}]}, "finish_reason" => "stop"}
        ]
      }

      result = Adapter.fix_tool_call_finish_reason(response)
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "stop"
    end
  end

  describe "build_forwarded_headers/2" do
    test "filters proxy override headers and appends proxy headers" do
      client_headers = [
        {"x-request-id", "123"},
        {"authorization", "Bearer client-token"},
        {"content-type", "text/plain"}
      ]

      proxy_headers = [
        {"Authorization", "Bearer proxy-token"},
        {"Content-Type", "application/json"}
      ]

      result = Adapter.build_forwarded_headers(client_headers, proxy_headers)

      assert {"x-request-id", "123"} in result
      assert {"Authorization", "Bearer proxy-token"} in result
      assert {"Content-Type", "application/json"} in result

      refute Enum.any?(result, fn {k, v} ->
               String.downcase(k) == "authorization" and v == "Bearer client-token"
             end)
    end

    test "strips x-api-key from client headers" do
      client_headers = [
        {"x-request-id", "123"},
        {"x-api-key", "client-anthropic-key"}
      ]

      proxy_headers = [
        {"Authorization", "Bearer proxy-token"}
      ]

      result = Adapter.build_forwarded_headers(client_headers, proxy_headers)

      assert {"x-request-id", "123"} in result
      assert {"Authorization", "Bearer proxy-token"} in result

      refute Enum.any?(result, fn {k, _} ->
               String.downcase(k) == "x-api-key"
             end)
    end

    test "handles nil client_headers" do
      proxy_headers = [{"Authorization", "Bearer test"}]
      result = Adapter.build_forwarded_headers(nil, proxy_headers)
      assert result == proxy_headers
    end
  end

  describe "can_handle?/2" do
    setup do
      model = %DodoRouter.Models.Model{
        supports_vision: false,
        supports_function_calling: false
      }

      %{model: model}
    end

    test "returns error for images when vision not supported", %{model: model} do
      request = %{"messages" => [%{"role" => "user", "content" => [%{"type" => "image_url"}]}]}
      assert {:error, :no_vision_support} = Adapter.can_handle?(request, model)
    end

    test "returns error for tools when function_calling not supported", %{model: model} do
      request = %{"messages" => [], "tools" => [%{"name" => "test"}]}
      assert {:error, :no_tool_support} = Adapter.can_handle?(request, model)
    end

    test "returns ok when no unsupported features", %{model: model} do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      assert :ok = Adapter.can_handle?(request, model)
    end
  end

  describe "merge_consecutive_roles/1" do
    test "merges consecutive tool messages" do
      messages = [
        %{"role" => "user", "content" => "use tool"},
        %{"role" => "tool", "content" => "result1", "tool_call_id" => "c1"},
        %{"role" => "tool", "content" => "result2", "tool_call_id" => "c2"}
      ]

      result = Adapter.merge_consecutive_roles(messages)
      assert length(result) == 2
      assert Enum.at(result, 0)["role"] == "user"
      merged = Enum.at(result, 1)
      assert merged["role"] == "tool"
      assert merged["content"] == "result1\nresult2"
    end

    test "merges consecutive user messages" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "user", "content" => "world"}
      ]

      result = Adapter.merge_consecutive_roles(messages)
      assert length(result) == 1
      assert Enum.at(result, 0)["content"] == "hello\nworld"
    end

    test "does not merge alternating roles" do
      messages = [
        %{"role" => "user", "content" => "hi"},
        %{"role" => "assistant", "content" => "hello"},
        %{"role" => "user", "content" => "bye"}
      ]

      result = Adapter.merge_consecutive_roles(messages)
      assert length(result) == 3
    end

    test "treats tool and user as separate roles" do
      messages = [
        %{"role" => "user", "content" => "use tool"},
        %{"role" => "tool", "content" => "result", "tool_call_id" => "c1"}
      ]

      result = Adapter.merge_consecutive_roles(messages)
      assert length(result) == 2
    end
  end

  describe "migrate_function_call/1" do
    test "converts deprecated function_call to tool_calls" do
      msg = %{
        "role" => "assistant",
        "function_call" => %{"name" => "read_file", "arguments" => "{\"path\": \"/tmp\"}"}
      }

      result = Adapter.migrate_function_call(msg)
      refute Map.has_key?(result, "function_call")
      assert length(result["tool_calls"]) == 1
      tc = hd(result["tool_calls"])
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "read_file"
      assert tc["function"]["arguments"] == "{\"path\": \"/tmp\"}"
    end

    test "generates an id when none present" do
      msg = %{"role" => "assistant", "function_call" => %{"name" => "test"}}
      result = Adapter.migrate_function_call(msg)
      assert String.starts_with?(hd(result["tool_calls"])["id"], "call_")
    end

    test "passes through messages without function_call" do
      msg = %{"role" => "assistant", "content" => "hi"}
      assert Adapter.migrate_function_call(msg) == msg
    end
  end

  describe "sanitize_request/1 migrate_function_call integration" do
    test "migrates function_call in messages during sanitization" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{
            "role" => "assistant",
            "content" => "",
            "function_call" => %{"name" => "test", "arguments" => "{}"}
          }
        ]
      }

      result = Adapter.sanitize_request(request)
      assistant_msg = Enum.find(result["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(assistant_msg, "function_call")
      assert is_list(assistant_msg["tool_calls"])
    end
  end
end
