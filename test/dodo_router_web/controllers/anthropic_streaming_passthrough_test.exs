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
    Process.put(:anthropic_sse_state, AnthropicFormat.new_sse_state())
    Process.put(:__anthropic_serving_model__, "claude-fable-5")
    Process.delete(:__stream_opened__)
    Process.delete(:__anthropic_passthrough_active__)

    on_exit(fn ->
      Process.delete(:__stream_conn__)
      Process.delete(:anthropic_sse_state)
      Process.delete(:__anthropic_serving_model__)
      Process.delete(:__stream_opened__)
      Process.delete(:__anthropic_passthrough_active__)
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
