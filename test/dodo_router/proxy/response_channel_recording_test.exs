defmodule DodoRouter.Proxy.ResponseChannelRecordingTest do
  @moduledoc """
  Channel 3 for providers with no client that speaks their format.

  There is nothing to restore — no Gemini or Cohere ingress — so the only
  honest thing an egress conversion can do with a field it cannot carry is
  say so. Until now only the Anthropic adapter did.
  """
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Cohere
  alias DodoRouter.Proxy.Adapters.Google
  alias DodoRouter.Proxy.Fidelity

  setup do
    Fidelity.reset()
    :ok
  end

  defp response_body_changes do
    Fidelity.take().changes
    |> Enum.filter(&(&1["channel"] == "response_body"))
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  describe "Gemini" do
    test "records the top-level fields the IR cannot carry" do
      Google.convert_to_openai_format(%{
        "candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}],
        "usageMetadata" => %{"promptTokenCount" => 1},
        "modelVersion" => "gemini-3.0-pro-001",
        "promptFeedback" => %{"blockReason" => "SAFETY"}
      })

      assert response_body_changes() == ["modelVersion", "promptFeedback"]
    end

    test "records nothing when everything was translated" do
      Google.convert_to_openai_format(%{
        "candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}],
        "usageMetadata" => %{"promptTokenCount" => 1}
      })

      assert response_body_changes() == []
    end
  end

  describe "Cohere" do
    test "records the top-level fields the IR cannot carry" do
      Cohere.convert_to_openai_format(%{
        "message" => %{"content" => [%{"text" => "hi"}]},
        "usage" => %{"tokens" => %{"input_tokens" => 1, "output_tokens" => 1}},
        "id" => "co_123",
        "finish_reason" => "COMPLETE"
      })

      assert response_body_changes() == ["finish_reason", "id"]
    end
  end
end
