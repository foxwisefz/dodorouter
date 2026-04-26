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
        Google.convert_to_openai_format(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => ""}]}, "finishReason" => "STOP"}]}),
        ["choices", Access.at(0), "finish_reason"]
      ) == "stop"

      assert get_in(
        Google.convert_to_openai_format(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => ""}]}, "finishReason" => "MAX_TOKENS"}]}),
        ["choices", Access.at(0), "finish_reason"]
      ) == "length"

      assert get_in(
        Google.convert_to_openai_format(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => ""}]}, "finishReason" => "SAFETY"}]}),
        ["choices", Access.at(0), "finish_reason"]
      ) == "content_filter"
    end

    test "handles empty candidates gracefully" do
      result = Google.convert_to_openai_format(%{})
      assert get_in(result, ["choices", Access.at(0), "message", "content"]) == ""
    end
  end
end
