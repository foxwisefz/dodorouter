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

  describe "categorize_error/2 for a retired model" do
    test "a 404 naming a model is model_not_found, not unknown" do
      # Anthropic answers a retired snapshot with 404 and a body naming the
      # model. Classified as `unknown` it read as a mystery server problem,
      # and the log recorded a blanket 502 — nothing said "that model no
      # longer exists", which is the one actionable fact.
      body = %{
        "error" => %{
          "message" => "model: claude-3-5-sonnet-20240620",
          "type" => "not_found_error"
        },
        "type" => "error"
      }

      assert Adapter.categorize_error(404, body) == :model_not_found
    end

    test "a 404 that names no model is still a not_found" do
      assert Adapter.categorize_error(404, %{"error" => %{"message" => "No such endpoint"}}) ==
               :not_found
    end

    test "another provider may still have the model, so the chain moves on" do
      assert Adapter.should_fallback?(:model_not_found)
      assert Adapter.should_fallback?(:not_found)
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

    test ":anthropic sets output_config.effort and adaptive thinking" do
      body = Adapter.inject_reasoning_effort(%{"max_tokens" => 4096}, "high", :anthropic)

      assert body["output_config"]["effort"] == "high"
      assert body["thinking"] == %{"type" => "adaptive"}
    end

    test ":anthropic never emits budget_tokens, which 400s on every current Claude model" do
      for level <- ~w(minimal low medium high xhigh max) do
        body = Adapter.inject_reasoning_effort(%{"max_tokens" => 4096}, level, :anthropic)
        refute Map.has_key?(body["thinking"], "budget_tokens"), "leaked a budget for #{level}"
      end
    end

    test ":anthropic leaves max_tokens exactly as the client set it" do
      # The old bump existed only to satisfy max_tokens > budget_tokens. With
      # no budget there is nothing to satisfy, and the ceiling is the client's.
      body = Adapter.inject_reasoning_effort(%{"max_tokens" => 512}, "max", :anthropic)
      assert body["max_tokens"] == 512
    end

    test ":anthropic folds 'minimal' into Anthropic's lowest level" do
      body = Adapter.inject_reasoning_effort(%{}, "minimal", :anthropic)
      assert body["output_config"]["effort"] == "low"
    end

    test ":anthropic disables thinking for 'none'" do
      body = Adapter.inject_reasoning_effort(%{}, "none", :anthropic)
      assert body["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(body, "output_config")
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

    test ":anthropic respects a client effort already in output_config" do
      body =
        Adapter.inject_reasoning_effort(
          %{"output_config" => %{"effort" => "low"}},
          "max",
          :anthropic
        )

      assert body["output_config"]["effort"] == "low"
    end

    test ":anthropic merges into output_config rather than replacing it" do
      # `format` carries structured outputs; dropping it would silently turn a
      # schema-constrained request into a free-text one.
      format = %{"type" => "json_schema", "schema" => %{"type" => "object"}}

      body =
        Adapter.inject_reasoning_effort(
          %{"output_config" => %{"format" => format}},
          "high",
          :anthropic
        )

      assert body["output_config"] == %{"format" => format, "effort" => "high"}
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

  describe "sanitize_request/1 with content parts" do
    test "flattens system parts arrays to a string for OpenAI-family providers" do
      request = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "system",
            "content" => [
              %{"type" => "text", "text" => "IDENTITY"},
              %{
                "type" => "text",
                "text" => "BIG PROMPT",
                "cache_control" => %{"type" => "ephemeral"}
              }
            ]
          },
          %{"role" => "user", "content" => "hi"}
        ]
      }

      [sys_msg | _] = Adapter.sanitize_request(request)["messages"]
      assert sys_msg["content"] == "IDENTITY\nBIG PROMPT"
    end

    # OpenAI-family chat APIs take a parts array on user messages precisely
    # so an image can ride alongside text. Flattening that array turned the
    # image into a JSON string the model read as prose — a request that
    # asked "what is in this picture?" got a 200 describing some JSON.
    test "keeps a user parts array that carries an image" do
      image = %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}}

      request = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "What is this?"}, image]
          }
        ]
      }

      [user_msg] = Adapter.sanitize_request(request)["messages"]
      assert user_msg["content"] == [%{"type" => "text", "text" => "What is this?"}, image]
    end

    test "still flattens a text-only user parts array" do
      request = %{
        "model" => "m",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "one"},
              %{"type" => "text", "text" => "two", "cache_control" => %{"type" => "ephemeral"}}
            ]
          }
        ]
      }

      [user_msg] = Adapter.sanitize_request(request)["messages"]
      assert user_msg["content"] == "one\ntwo"
    end
  end
end
