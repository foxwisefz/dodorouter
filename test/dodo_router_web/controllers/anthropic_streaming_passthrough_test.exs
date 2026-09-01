defmodule DodoRouterWeb.AnthropicStreamingPassthroughTest do
  @moduledoc """
  The egress half of streaming passthrough (dodo_router-m9w): native events
  relayed by an Anthropic step must reach the client verbatim, with no
  synthetic message lifecycle wrapped around them — the provider's own
  message_start/message_stop are already on the wire.

  Exercises the controller's stream-chunk router directly with a Plug.Test
  conn parked where the real dispatch parks it.
  """
  use ExUnit.Case, async: false

  alias DodoRouterWeb.AnthropicFormat
  alias DodoRouterWeb.AnthropicProxyController

  setup do
    conn = Plug.Test.conn(:post, "/r/test/v1/messages")
    Process.put(:__stream_conn__, conn)
    Process.put(:__anthropic_serving_model__, "claude-fable-5")
    # As production does: the reframing state is created lazily by
    # handle_stream_data/2, never seeded up front — lazy creation is what
    # detects a reframed step joining a passthrough-started stream.
    Process.delete(:anthropic_sse_state)
    Process.delete(:__stream_opened__)
    Process.delete(:__anthropic_passthrough_active__)
    Process.delete(:__anthropic_native_blocks__)
    Process.delete(:__anthropic_pending_join__)
    Process.delete(:__anthropic_reframe_joined__)

    on_exit(fn ->
      Process.delete(:__stream_conn__)
      Process.delete(:anthropic_sse_state)
      Process.delete(:__anthropic_serving_model__)
      Process.delete(:__stream_opened__)
      Process.delete(:__anthropic_passthrough_active__)
      Process.delete(:__anthropic_native_blocks__)
      Process.delete(:__anthropic_pending_join__)
      Process.delete(:__anthropic_reframe_joined__)
    end)

    :ok
  end

  defp sent_body do
    Process.get(:__stream_conn__).resp_body || ""
  end

  defp native(event) do
    "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
  end

  test "native events are relayed verbatim with no synthetic lifecycle" do
    events = [
      %{
        "type" => "message_start",
        "message" => %{"id" => "msg_01real", "model" => "claude-fable-5"}
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig_abc"}
      },
      %{"type" => "message_stop"}
    ]

    for event <- events do
      :ok = AnthropicProxyController.handle_stream_data(native(event), "req-1")
    end

    body = sent_body()

    assert body == Enum.map_join(events, "", &native/1)
    # exactly the provider's message_start — no synthetic one with zeroed usage
    assert length(String.split(body, "event: message_start")) == 2
    refute body =~ ~s("input_tokens":0)
  end

  test "finish_stream is a no-op after passthrough relayed the real terminator" do
    :ok =
      AnthropicProxyController.handle_stream_data(
        native(%{"type" => "message_stop"}),
        "req-1"
      )

    before = sent_body()

    AnthropicProxyController.finish_stream(
      {:ok, %{"choices" => []}, %{}},
      AnthropicFormat.new_sse_state(),
      "req-1",
      fn _ -> :ok end
    )

    assert sent_body() == before
  end

  defp parse_wire(wire) do
    ~r/event: (\S+)\ndata: (.*?)\n\n/s
    |> Regex.scan(wire)
    |> Enum.map(fn [_, _type, json] -> Jason.decode!(json) end)
  end

  test "a reframed fallback joining a dead passthrough stream continues the block lifecycle" do
    # The midstream-failover seam: an Anthropic step relayed native events
    # (a thinking block, then an open text block), then died; FallbackChain
    # reconstructs and an OpenAI-family step continues the same client
    # stream, reframed. The client's wire must stay legal Anthropic SSE —
    # close the block the dead provider left open, continue at fresh
    # indexes, and finish with a real tail (the native terminator never
    # flowed). Regression: the continuation used to land text_deltas on
    # index 0 — the thinking block — and Claude Code aborted with
    # "Content block is not a text block".
    native_events = [
      %{
        "type" => "message_start",
        "message" => %{"id" => "msg_01real", "model" => "claude-opus-4-8"}
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "hm"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "The sky is "}
      }
    ]

    for event <- native_events do
      :ok = AnthropicProxyController.handle_stream_data(native(event), "req-1")
    end

    chunk =
      "data: " <>
        Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "blue."}}]}) <>
        "\n\n"

    :ok = AnthropicProxyController.handle_stream_data(chunk, "req-1")

    tail_fun = fn data ->
      Process.put(:__test_tail__, Process.get(:__test_tail__, "") <> data)
      :ok
    end

    AnthropicProxyController.finish_stream(
      {:ok,
       %{
         "choices" => [%{"index" => 0, "finish_reason" => "stop", "message" => %{}}],
         "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7}
       }, %{}},
      Process.get(:anthropic_sse_state),
      "req-1",
      tail_fun
    )

    body = sent_body()
    native_wire = Enum.map_join(native_events, "", &native/1)

    # The native part reached the client verbatim, and only the provider's
    # message_start is on the wire — the join must not open a second message.
    assert String.starts_with?(body, native_wire)
    assert length(String.split(body, "event: message_start")) == 2

    joined = parse_wire(String.replace_prefix(body, native_wire, ""))

    assert [
             %{"type" => "content_block_stop", "index" => 1},
             %{
               "type" => "content_block_start",
               "index" => 2,
               "content_block" => %{"type" => "text"}
             },
             %{
               "type" => "content_block_delta",
               "index" => 2,
               "delta" => %{"type" => "text_delta", "text" => "blue."}
             }
           ] = joined

    tail = parse_wire(Process.get(:__test_tail__, ""))
    Process.delete(:__test_tail__)

    assert [
             %{"type" => "content_block_stop", "index" => 2},
             %{"type" => "message_delta"},
             %{"type" => "message_stop"}
           ] = Enum.map(tail, &Map.take(&1, ["type", "index"]))
  end

  test "OpenAI chunks still get the synthetic lifecycle (reframe unchanged)" do
    chunk =
      "data: " <>
        Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}}]}) <>
        "\n\n"

    :ok = AnthropicProxyController.handle_stream_data(chunk, "req-1")

    body = sent_body()
    assert body =~ "event: message_start"
    assert body =~ "event: content_block_start"
    assert body =~ "text_delta"
    refute Process.get(:__anthropic_passthrough_active__)
  end
end
