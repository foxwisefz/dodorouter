defmodule DodoRouterWeb.ResponsesNullableToolsTest do
  use ExUnit.Case, async: true

  alias DodoRouterWeb.ResponsesFormat

  test "null tool_calls preserves text and metadata just like absent or empty tool calls" do
    for content <- ["A normal model reply", "", nil] do
      message = %{"role" => "assistant", "content" => content}

      response = fn message ->
        ResponsesFormat.from_openai_response(
          %{
            "choices" => [%{"message" => message, "finish_reason" => "stop"}],
            "model" => "served-model",
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3, "total_tokens" => 13}
          },
          "nullable-tools"
        )
      end

      expected = response.(message)
      assert response.(Map.put(message, "tool_calls", nil)) == expected
      assert response.(Map.put(message, "tool_calls", [])) == expected
      assert expected["output_text"] == (content || "")
      assert expected["model"] == "served-model"
      assert expected["usage"]["output_tokens"] == 3
    end
  end
end
