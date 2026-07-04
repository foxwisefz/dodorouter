defmodule DodoRouter.Proxy.AdapterTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter

  describe "context_overflow?/2" do
    test "detects z.ai 200-OK overflow via finish_reason" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "model_context_window_exceeded",
            "message" => %{"content" => "", "role" => "assistant"}
          }
        ],
        "usage" => nil
      }

      assert Adapter.context_overflow?(body)
    end

    test "detects OpenAI error code" do
      body = %{
        "error" => %{
          "code" => "context_length_exceeded",
          "message" => "This model's maximum context length is 8192 tokens"
        }
      }

      assert Adapter.context_overflow?(body)
    end

    test "detects OpenAI stream error" do
      body = %{
        "type" => "error",
        "error" => %{
          "code" => "context_length_exceeded",
          "message" => "Input exceeds context window"
        }
      }

      assert Adapter.context_overflow?(body)
    end

    test "detects Anthropic message" do
      body = %{"error" => %{"message" => "prompt is too long"}}
      assert Adapter.context_overflow?(body)
    end

    test "detects Moonshot/Kimi message" do
      body = %{
        "error" => %{
          "message" =>
            "Invalid request: Your request exceeded model token limit: 262144 (requested: 265359)",
          "type" => "invalid_request_error"
        }
      }

      assert Adapter.context_overflow?(body)
    end

    test "detects Gemini message" do
      body = %{"error" => %{"message" => "input token count (5000) exceeds the maximum (4000)"}}
      assert Adapter.context_overflow?(body)
    end

    test "detects generic context length exceeded" do
      body = %{"error" => %{"message" => "context length exceeded"}}
      assert Adapter.context_overflow?(body)
    end

    test "returns false for non-overflow errors" do
      body = %{"error" => %{"message" => "invalid api key"}}
      refute Adapter.context_overflow?(body)
    end

    test "returns false for successful responses" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"content" => "Hello!", "role" => "assistant"}
          }
        ]
      }

      refute Adapter.context_overflow?(body)
    end
  end

  describe "categorize_error/2" do
    test "categorizes context_overflow from finish_reason" do
      body = %{
        "choices" => [
          %{
            "finish_reason" => "model_context_window_exceeded",
            "message" => %{"content" => ""}
          }
        ]
      }

      assert Adapter.categorize_error(200, body) == :context_overflow
    end

    test "categorizes context_overflow from error code" do
      body = %{"error" => %{"code" => "context_length_exceeded", "message" => "too long"}}
      assert Adapter.categorize_error(400, body) == :context_overflow
    end

    test "categorizes context_overflow from HTTP 413" do
      body = %{"error" => %{"message" => "request too large"}}
      assert Adapter.categorize_error(413, body) == :context_overflow
    end

    test "categorizes context_overflow from error message" do
      body = %{"error" => %{"message" => "prompt is too long"}}
      assert Adapter.categorize_error(400, body) == :context_overflow
    end

    test "categorizes regular 400 as bad_request" do
      body = %{"error" => %{"message" => "invalid parameter"}}
      assert Adapter.categorize_error(400, body) == :bad_request
    end
  end

  describe "parse_sse_chunk/2" do
    test "parses single SSE event" do
      data = ~s|data: {"id":"123","choices":[{"delta":{"content":"hello"}}]}\n\n|

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks, [chunk]} = result
      assert chunk["id"] == "123"
    end

    test "parses multiple batched SSE events" do
      data = """
      data: {"id":"1","choices":[{"delta":{"content":"a"}}]}

      data: {"id":"2","choices":[{"delta":{"content":"b"}}]}

      data: {"id":"3","choices":[{"delta":{"content":"c"}}]}

      """

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks, chunks} = result
      assert length(chunks) == 3
      assert Enum.map(chunks, & &1["id"]) == ["1", "2", "3"]
    end

    test "handles batched events with tool_calls" do
      data = """
      data: {"id":"tc1","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read"}}]}}]}

      data: {"id":"tc2","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\""}}]}}]}

      data: {"id":"tc3","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\": \\"/tmp\\"}"}}]}}]}

      """

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks, chunks} = result
      assert length(chunks) == 3

      # First chunk has the tool call id and name
      first = hd(chunks)
      tc = get_in(first, ["choices", Access.at(0), "delta", "tool_calls", Access.at(0)])
      assert tc["id"] == "call_1"
      assert tc["function"]["name"] == "read"
    end

    test "returns :done for [DONE] signal" do
      data = "data: [DONE]\n\n"

      assert Adapter.parse_sse_chunk(data, "") == {:done, ""}
    end

    test "returns chunks_then_done when data ends with [DONE]" do
      data = """
      data: {"id":"final","choices":[{"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks_then_done, [chunk]} = result
      assert chunk["id"] == "final"
    end

    test "returns :skip for empty or non-SSE data" do
      assert Adapter.parse_sse_chunk("", "") == {:skip, ""}
      assert Adapter.parse_sse_chunk("\n\n", "") == {:skip, ""}
      assert Adapter.parse_sse_chunk("not sse data", "") == {:skip, "not sse data"}
    end

    # Some endpoints send SSE without space after colon
    test "parses SSE without space after data: (no-space format)" do
      data = ~s|data:{"id":"123","choices":[{"delta":{"content":"hello"}}]}\n\n|

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks, [chunk]} = result
      assert chunk["id"] == "123"
      assert get_in(chunk, ["choices", Access.at(0), "delta", "content"]) == "hello"
    end

    test "parses multiple batched SSE events without space" do
      data = """
      data:{"id":"1","choices":[{"delta":{"reasoning_content":"thinking"}}]}

      data:{"id":"2","choices":[{"delta":{"content":"answer"}}]}

      """

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks, chunks} = result
      assert length(chunks) == 2
      assert Enum.map(chunks, & &1["id"]) == ["1", "2"]
    end

    test "handles [DONE] without space" do
      data = "data:[DONE]\n\n"

      assert Adapter.parse_sse_chunk(data, "") == {:done, ""}
    end

    test "handles chunks_then_done without space" do
      data = """
      data:{"id":"final","choices":[{"delta":{},"finish_reason":"stop"}]}

      data:[DONE]

      """

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks_then_done, [chunk]} = result
      assert chunk["id"] == "final"
    end

    test "handles mixed space/no-space format in same batch" do
      data = """
      data: {"id":"1","choices":[{"delta":{"content":"a"}}]}

      data:{"id":"2","choices":[{"delta":{"content":"b"}}]}

      """

      {result, _buffer} = Adapter.parse_sse_chunk(data, "")

      assert {:chunks, chunks} = result
      assert length(chunks) == 2
    end

    test "buffers incomplete lines across chunks" do
      # First chunk has incomplete line (no trailing newline)
      {result1, buffer1} =
        Adapter.parse_sse_chunk(
          "data: {\"id\":\"1\",\"choices\":[{\"delta\":{\"content\":\"Hel",
          ""
        )

      assert result1 == :skip
      assert buffer1 == "data: {\"id\":\"1\",\"choices\":[{\"delta\":{\"content\":\"Hel"

      # Second chunk completes the line
      {result2, buffer2} = Adapter.parse_sse_chunk("lo\"}}]}\n\n", buffer1)
      assert {:chunks, [chunk]} = result2
      assert get_in(chunk, ["choices", Access.at(0), "delta", "content"]) == "Hello"
      assert buffer2 == ""
    end
  end

  describe "capture_streamed_error/2 and streamed_error_body/1" do
    test "accumulates chunks and decodes JSON error bodies" do
      resp = Req.Response.new(status: 400)

      {:cont, {_req, resp}} =
        Adapter.capture_streamed_error({:data, ~s({"error": {"message":)}, {:req, resp})

      {:cont, {_req, resp}} =
        Adapter.capture_streamed_error({:data, ~s( "bad effort"}})}, {:req, resp})

      assert Adapter.streamed_error_body(resp) == %{
               "error" => %{"message" => "bad effort"}
             }
    end

    test "returns raw string when body is not JSON" do
      resp = Req.Response.new(status: 502)
      {:cont, {_req, resp}} = Adapter.capture_streamed_error({:data, "Bad Gateway"}, {:req, resp})

      assert Adapter.streamed_error_body(resp) == "Bad Gateway"
    end

    test "falls back to Req.Response body when nothing was captured" do
      resp = Req.Response.new(status: 400, body: "plain")
      assert Adapter.streamed_error_body(resp) == "plain"
    end
  end

  describe "inject_reasoning_effort/3" do
    test "no-op when effort is nil or empty" do
      body = %{"model" => "x"}
      assert Adapter.inject_reasoning_effort(body, nil, :openai) == body
      assert Adapter.inject_reasoning_effort(body, "", :openai) == body
    end

    test ":none format is always a no-op" do
      body = %{"model" => "x"}
      assert Adapter.inject_reasoning_effort(body, "high", :none) == body
    end

    test ":openai sets top-level reasoning_effort" do
      body = Adapter.inject_reasoning_effort(%{"model" => "x"}, "high", :openai)
      assert body["reasoning_effort"] == "high"
    end

    test ":openai passes any effort through verbatim (no clamping)" do
      assert Adapter.inject_reasoning_effort(%{}, "xhigh", :openai)["reasoning_effort"] == "xhigh"
      assert Adapter.inject_reasoning_effort(%{}, "max", :openai)["reasoning_effort"] == "max"
      assert Adapter.inject_reasoning_effort(%{}, "none", :openai)["reasoning_effort"] == "none"

      assert Adapter.inject_reasoning_effort(%{}, "default", :openai)["reasoning_effort"] ==
               "default"
    end

    test ":openai respects a client-supplied reasoning_effort" do
      body = Adapter.inject_reasoning_effort(%{"reasoning_effort" => "low"}, "high", :openai)
      assert body["reasoning_effort"] == "low"
    end

    test ":on_off enables thinking for any non-none level" do
      body = Adapter.inject_reasoning_effort(%{}, "high", :on_off)
      assert body["thinking"] == %{"type" => "enabled"}
    end

    test ":on_off disables thinking for 'none'" do
      body = Adapter.inject_reasoning_effort(%{}, "none", :on_off)
      assert body["thinking"] == %{"type" => "disabled"}
    end

    test ":on_off respects an existing thinking field" do
      body =
        Adapter.inject_reasoning_effort(%{"thinking" => %{"type" => "enabled"}}, "none", :on_off)

      assert body["thinking"] == %{"type" => "enabled"}
    end

    test ":anthropic sets thinking with a token budget" do
      body = Adapter.inject_reasoning_effort(%{"max_tokens" => 64_000}, "high", :anthropic)
      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 16_000}
      # Keeps client max_tokens since it exceeds the budget
      assert body["max_tokens"] == 64_000
    end

    test ":anthropic bumps max_tokens when it does not exceed the budget" do
      body = Adapter.inject_reasoning_effort(%{"max_tokens" => 4096}, "high", :anthropic)
      assert body["max_tokens"] > 16_000
    end

    test ":anthropic respects an existing thinking field" do
      body =
        Adapter.inject_reasoning_effort(
          %{"thinking" => %{"type" => "disabled"}},
          "high",
          :anthropic
        )

      assert body["thinking"] == %{"type" => "disabled"}
    end

    test ":gemini sets generationConfig.thinkingConfig.thinkingBudget" do
      body = Adapter.inject_reasoning_effort(%{}, "high", :gemini)
      assert get_in(body, ["generationConfig", "thinkingConfig", "thinkingBudget"]) == 16_384
    end

    test ":gemini preserves an existing client thinkingBudget" do
      body =
        Adapter.inject_reasoning_effort(
          %{"generationConfig" => %{"thinkingConfig" => %{"thinkingBudget" => 1000}}},
          "high",
          :gemini
        )

      assert get_in(body, ["generationConfig", "thinkingConfig", "thinkingBudget"]) == 1000
    end

    test ":responses sets reasoning.effort" do
      body = Adapter.inject_reasoning_effort(%{}, "high", :responses)
      assert body["reasoning"] == %{"effort" => "high"}
    end

    test ":responses respects an existing reasoning field" do
      body =
        Adapter.inject_reasoning_effort(
          %{"reasoning" => %{"effort" => "low"}},
          "high",
          :responses
        )

      assert body["reasoning"] == %{"effort" => "low"}
    end

    test ":responses passes any effort through verbatim (no clamping)" do
      assert Adapter.inject_reasoning_effort(%{}, "xhigh", :responses)["reasoning"] ==
               %{"effort" => "xhigh"}

      assert Adapter.inject_reasoning_effort(%{}, "max", :responses)["reasoning"] ==
               %{"effort" => "max"}

      assert Adapter.inject_reasoning_effort(%{}, "none", :responses)["reasoning"] ==
               %{"effort" => "none"}
    end
  end
end
