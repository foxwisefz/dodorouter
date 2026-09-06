defmodule DodoRouterWeb.ResponsesUsageFidelityTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.ResponsesAPI
  alias DodoRouterWeb.ResponsesFormat

  test "provider cache and reasoning details survive normalization and Responses egress" do
    for cached <- [0, 800] do
      usage = %{
        "input_tokens" => 1000,
        "output_tokens" => 50,
        "total_tokens" => 1050,
        "input_tokens_details" => %{"cached_tokens" => cached, "cache_write_tokens" => 0},
        "output_tokens_details" => %{"reasoning_tokens" => 20}
      }

      response =
        ResponsesFormat.from_openai_response(
          %{"usage" => ResponsesAPI.convert_usage(usage)},
          "test"
        )

      assert response["usage"] == usage
    end
  end

  test "egress reports each response's usage without accumulating earlier turns" do
    for input <- [1000, 1032] do
      usage = %{
        "prompt_tokens" => input,
        "completion_tokens" => 7,
        "total_tokens" => input + 7,
        "prompt_tokens_details" => %{"cached_tokens" => 800}
      }

      result = ResponsesFormat.from_openai_response(%{"usage" => usage}, "turn-#{input}")
      assert result["usage"]["input_tokens"] == input
      assert result["usage"]["input_tokens_details"] == %{"cached_tokens" => 800}
    end
  end
end
