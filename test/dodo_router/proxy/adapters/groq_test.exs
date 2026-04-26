defmodule DodoRouter.Proxy.Adapters.GroqTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Groq

  describe "transform_request/1" do
    test "strips null function_call from assistant messages" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{"role" => "assistant", "content" => "hello", "function_call" => nil}
        ]
      }

      result = Groq.transform_request(request)
      assistant_msg = Enum.find(result["messages"], &(&1["role"] == "assistant"))
      refute Map.has_key?(assistant_msg, "function_call")
    end

    test "keeps non-null function_call" do
      request = %{
        "messages" => [
          %{
            "role" => "assistant",
            "content" => "",
            "function_call" => %{"name" => "test", "arguments" => "{}"}
          }
        ]
      }

      result = Groq.transform_request(request)
      assistant_msg = hd(result["messages"])
      assert Map.has_key?(assistant_msg, "function_call")
    end
  end

  describe "needs_fake_stream?/1" do
    test "returns true when response_format present" do
      request = %{"response_format" => %{"type" => "json_object"}}
      assert Groq.needs_fake_stream?(request) == true
    end

    test "returns false when no response_format" do
      request = %{}
      assert Groq.needs_fake_stream?(request) == false
    end
  end
end
