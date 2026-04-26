defmodule DodoRouter.Proxy.Adapters.CohereTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Cohere
  alias DodoRouter.Routers.RoutingStep

  describe "build_cohere_request/2" do
    test "maps OpenAI params to Cohere params" do
      request = %{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "top_p" => 0.9,
        "n" => 2,
        "stop" => ["\n"]
      }

      step = %RoutingStep{model: "command-r-plus"}
      body = Cohere.build_cohere_request(request, step)

      assert body["p"] == 0.9
      assert body["num_generations"] == 2
      assert body["stop_sequences"] == ["\n"]
      refute Map.has_key?(body, "top_p")
      refute Map.has_key?(body, "n")
      refute Map.has_key?(body, "stop")
    end

    test "sets model from step" do
      request = %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      step = %RoutingStep{model: "command-r"}

      body = Cohere.build_cohere_request(request, step)
      assert body["model"] == "command-r"
    end
  end

  describe "convert_to_openai_format/1" do
    test "converts text response" do
      cohere_response = %{
        "message" => %{
          "content" => [%{"text" => "Hello!"}]
        },
        "usage" => %{
          "tokens" => %{"input_tokens" => 10, "output_tokens" => 5}
        }
      }

      result = Cohere.convert_to_openai_format(cohere_response)

      assert get_in(result, ["choices", Access.at(0), "message", "content"]) == "Hello!"
      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "converts tool_calls response" do
      cohere_response = %{
        "message" => %{
          "content" => [%{"text" => ""}],
          "tool_calls" => [
            %{
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "test", "arguments" => "{}"}
            }
          ]
        }
      }

      result = Cohere.convert_to_openai_format(cohere_response)
      message = get_in(result, ["choices", Access.at(0), "message"])
      assert length(message["tool_calls"]) == 1
      assert hd(message["tool_calls"])["index"] == 0
    end

    test "handles missing usage gracefully" do
      cohere_response = %{
        "message" => %{"content" => [%{"text" => "hi"}]}
      }

      result = Cohere.convert_to_openai_format(cohere_response)
      refute Map.has_key?(result, "usage")
    end
  end
end
