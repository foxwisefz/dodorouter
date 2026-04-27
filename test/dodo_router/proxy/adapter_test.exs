defmodule DodoRouter.Proxy.AdapterTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter

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
end
