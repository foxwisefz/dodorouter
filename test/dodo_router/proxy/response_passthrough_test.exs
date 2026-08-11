defmodule DodoRouter.Proxy.ChannelThreeTest do
  @moduledoc """
  Channel 3: what the provider sent back that the client never sees.

  Same rule as the request side — the loss is at the IR, not the provider, so
  an Anthropic response returned to an Anthropic client round-trips whole, and
  only a client in another format loses it.
  """
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.Anthropic
  alias DodoRouterWeb.AnthropicFormat

  defp anthropic_response do
    %{
      "id" => "msg_01realid",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-4-6-20251101",
      "content" => [%{"type" => "text", "text" => "hi"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 2},
      "context_management" => %{"applied_edits" => [%{"type" => "clear_tool_uses_20250919"}]},
      "stop_details" => %{"type" => "refusal", "category" => "cyber"},
      "container" => %{"id" => "cont_01"}
    }
  end

  describe "the sync round trip" do
    test "native fields the IR cannot hold survive back to an Anthropic client" do
      ir = Anthropic.convert_to_openai_format(anthropic_response())
      {passthrough, ir} = Map.pop(ir, Adapter.response_passthrough_key())

      client = AnthropicFormat.from_openai_response(ir, passthrough)

      assert client["context_management"] == %{
               "applied_edits" => [%{"type" => "clear_tool_uses_20250919"}]
             }

      assert client["stop_details"] == %{"type" => "refusal", "category" => "cyber"}
      assert client["container"] == %{"id" => "cont_01"}
    end

    test "the real message id comes back instead of a synthesised one" do
      # It names a message in Anthropic's store — cache diagnostics reference
      # it — so inventing one throws away something the client can use.
      ir = Anthropic.convert_to_openai_format(anthropic_response())
      {passthrough, ir} = Map.pop(ir, Adapter.response_passthrough_key())

      assert AnthropicFormat.from_openai_response(ir, passthrough)["id"] == "msg_01realid"
    end

    test "the provider's id never becomes the IR's, which OpenAI clients read" do
      ir = Anthropic.convert_to_openai_format(anthropic_response())

      refute ir["id"] == "msg_01realid"
    end

    test "a client with no passthrough still gets a well-formed message" do
      # Every other provider: nothing native to restore, so the egress
      # synthesises an id exactly as before.
      ir = Anthropic.convert_to_openai_format(anthropic_response())
      {_passthrough, ir} = Map.pop(ir, Adapter.response_passthrough_key())

      client = AnthropicFormat.from_openai_response(ir)

      assert String.starts_with?(client["id"], "msg_")
      assert client["type"] == "message"
      refute Map.has_key?(client, "context_management")
    end

    test "translated fields are not duplicated into the passthrough" do
      ir = Anthropic.convert_to_openai_format(anthropic_response())
      passthrough = Map.fetch!(ir, Adapter.response_passthrough_key())

      for translated <- ~w(content stop_reason usage model) do
        refute Map.has_key?(passthrough, translated),
               "#{translated} is translated and must not also ride the passthrough"
      end
    end
  end

  describe "the streaming tail" do
    test "message_delta extras reach the accumulator" do
      {acc, _chunks} =
        Anthropic.process_anthropic_events(Anthropic.initial_stream_acc(), [
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "stop_sequence", "stop_sequence" => "END"},
            "usage" => %{"output_tokens" => 5},
            "context_management" => %{"applied_edits" => []}
          }
        ])

      assert acc.stop_reason == "stop_sequence"
      assert acc.passthrough["stop_sequence"] == "END"
      assert acc.passthrough["context_management"] == %{"applied_edits" => []}
      refute Map.has_key?(acc.passthrough, "stop_reason")
    end
  end
end
