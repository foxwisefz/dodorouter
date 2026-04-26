defmodule DodoRouter.Proxy.Adapters.GoogleTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Google

  describe "build_gemini_request/1" do
    test "extracts system message to systemInstruction" do
      request = %{
        "messages" => [
          %{"role" => "system", "content" => "Be helpful"},
          %{"role" => "user", "content" => "hi"}
        ]
      }

      result = Google.build_gemini_request(request)
      assert get_in(result, ["systemInstruction", "parts", Access.at(0), "text"]) == "Be helpful"

      roles = Enum.map(result["contents"], & &1["role"])
      assert "system" not in roles
    end

    test "maps assistant role to model" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{"role" => "assistant", "content" => "hello"}
        ]
      }

      result = Google.build_gemini_request(request)
      roles = Enum.map(result["contents"], & &1["role"])
      assert roles == ["user", "model"]
    end

    test "maps generation config params" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "temperature" => 0.7,
        "top_p" => 0.9,
        "max_tokens" => 100,
        "stop" => ["\n"]
      }

      result = Google.build_gemini_request(request)
      gen_config = result["generationConfig"]

      assert gen_config["temperature"] == 0.7
      assert gen_config["topP"] == 0.9
      assert gen_config["maxOutputTokens"] == 100
      assert gen_config["stopSequences"] == ["\n"]
    end

    test "omits generationConfig when no params" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      result = Google.build_gemini_request(request)
      refute Map.has_key?(result, "generationConfig")
    end

    test "wraps stop string in list" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "stop" => "END"
      }

      result = Google.build_gemini_request(request)
      assert result["generationConfig"]["stopSequences"] == ["END"]
    end
  end

  describe "convert_to_openai_format/1" do
    test "converts text response" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Hello!"}]},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      result = Google.convert_to_openai_format(gemini_response)

      assert get_in(result, ["choices", Access.at(0), "message", "content"]) == "Hello!"
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "stop"
      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "maps finish reasons" do
      assert get_in(
               Google.convert_to_openai_format(%{
                 "candidates" => [
                   %{"content" => %{"parts" => [%{"text" => ""}]}, "finishReason" => "STOP"}
                 ]
               }),
               ["choices", Access.at(0), "finish_reason"]
             ) == "stop"

      assert get_in(
               Google.convert_to_openai_format(%{
                 "candidates" => [
                   %{"content" => %{"parts" => [%{"text" => ""}]}, "finishReason" => "MAX_TOKENS"}
                 ]
               }),
               ["choices", Access.at(0), "finish_reason"]
             ) == "length"

      assert get_in(
               Google.convert_to_openai_format(%{
                 "candidates" => [
                   %{"content" => %{"parts" => [%{"text" => ""}]}, "finishReason" => "SAFETY"}
                 ]
               }),
               ["choices", Access.at(0), "finish_reason"]
             ) == "content_filter"
    end

    test "handles empty candidates gracefully" do
      result = Google.convert_to_openai_format(%{})
      assert get_in(result, ["choices", Access.at(0), "message", "content"]) == ""
    end
  end

  describe "tool/function calling" do
    test "converts tools to Gemini functionDeclarations" do
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

      result = Google.build_gemini_request(request)
      tools = result["tools"]
      assert is_list(tools)
      decls = hd(tools)["functionDeclarations"]
      assert length(decls) == 1
      assert hd(decls)["name"] == "read_file"
      assert hd(decls)["description"] == "Read a file"
    end

    test "converts assistant tool_calls to Gemini functionCall parts" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "read file"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "c1",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => "{\"path\": \"/tmp\"}"}
              }
            ]
          }
        ]
      }

      result = Google.build_gemini_request(request)
      model_msg = Enum.find(result["contents"], &(&1["role"] == "model"))
      assert model_msg != nil
      fc_part = Enum.find(model_msg["parts"], &Map.has_key?(&1, "functionCall"))
      assert fc_part["functionCall"]["name"] == "read_file"
      assert fc_part["functionCall"]["args"] == %{"path" => "/tmp"}
    end

    test "converts Gemini functionCall response to OpenAI tool_calls" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Using tool"},
                %{
                  "functionCall" => %{
                    "name" => "read_file",
                    "args" => %{"path" => "/tmp"}
                  }
                }
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      result = Google.convert_to_openai_format(gemini_response)

      message = get_in(result, ["choices", Access.at(0), "message"])
      assert message["content"] == "Using tool"
      assert length(message["tool_calls"]) == 1
      tc = hd(message["tool_calls"])
      assert tc["function"]["name"] == "read_file"
      assert Jason.decode!(tc["function"]["arguments"]) == %{"path" => "/tmp"}
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"
    end

    test "STOP finish_reason with no function calls maps to stop" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Hello!"}]},
            "finishReason" => "STOP"
          }
        ]
      }

      result = Google.convert_to_openai_format(gemini_response)
      assert get_in(result, ["choices", Access.at(0), "finish_reason"]) == "stop"
    end

    test "handles malformed JSON in assistant tool_call arguments gracefully" do
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
                "function" => %{"name" => "test", "arguments" => "not json{{{"}
              }
            ]
          }
        ]
      }

      result = Google.build_gemini_request(request)
      model_msg = Enum.find(result["contents"], &(&1["role"] == "model"))
      fc_part = Enum.find(model_msg["parts"], &Map.has_key?(&1, "functionCall"))
      assert fc_part["functionCall"]["args"] == %{}
    end
  end

  describe "consecutive role merging" do
    test "merges consecutive tool messages into single user content" do
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

      result = Google.build_gemini_request(request)
      roles = Enum.map(result["contents"], & &1["role"])
      assert roles == ["user", "model", "user"]
    end
  end

  describe "multimodal content" do
    test "converts image_url with base64 data URI to inlineData" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What is this?"},
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64,iVBORw0KGgo="}
              }
            ]
          }
        ]
      }

      result = Google.build_gemini_request(request)
      parts = hd(result["contents"])["parts"]

      text_part = Enum.find(parts, &Map.has_key?(&1, "text"))
      assert text_part["text"] == "What is this?"

      inline_part = Enum.find(parts, &Map.has_key?(&1, "inlineData"))
      assert inline_part["inlineData"]["mimeType"] == "image/png"
      assert inline_part["inlineData"]["data"] == "iVBORw0KGgo="
    end
  end

  describe "safety settings" do
    test "sets BLOCK_NONE for all harm categories" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      result = Google.build_gemini_request(request)

      assert is_list(result["safetySettings"])
      assert length(result["safetySettings"]) == 4

      for setting <- result["safetySettings"] do
        assert setting["threshold"] == "BLOCK_NONE"
      end

      categories = Enum.map(result["safetySettings"], & &1["category"]) |> Enum.sort()
      assert "HARM_CATEGORY_DANGEROUS_CONTENT" in categories
      assert "HARM_CATEGORY_HARASSMENT" in categories
      assert "HARM_CATEGORY_HATE_SPEECH" in categories
      assert "HARM_CATEGORY_SEXUALLY_EXPLICIT" in categories
    end
  end
end
