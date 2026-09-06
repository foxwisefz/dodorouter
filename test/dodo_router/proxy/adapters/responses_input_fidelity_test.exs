defmodule DodoRouter.Proxy.Adapters.ResponsesInputFidelityTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.ResponsesAPI
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouterWeb.ResponsesFormat

  defp round_trip(input) do
    %{"model" => "client-alias", "input" => input}
    |> ResponsesFormat.to_openai_params()
    |> ResponsesAPI.build_request_body(%RoutingStep{model: "served-model"})
  end

  test "Codex additional_tools remains a typed item, not a null developer message" do
    item = %{
      "type" => "additional_tools",
      "id" => "tools_1",
      "role" => "developer",
      "tools" => [
        %{"type" => "function", "name" => "lookup", "parameters" => %{"type" => "object"}}
      ]
    }

    body = round_trip([item, %{"role" => "user", "content" => "pong"}])

    assert [^item, %{"role" => "user", "content" => [%{"text" => "pong"}]}] = body["input"]
    refute Map.has_key?(hd(body["input"]), "content")
    assert body["model"] == "served-model"
  end

  test "typed items with role and content are not mistaken for messages at ingress" do
    item = %{
      "type" => "future_typed_item",
      "id" => "future_1",
      "role" => "assistant",
      "content" => [%{"type" => "opaque", "value" => "kept"}],
      "extra" => %{"enabled" => true}
    }

    assert round_trip([item])["input"] == [item]
  end

  test "roleless reasoning and tool history survive in order alongside normal messages" do
    items = [
      %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "opaque", "summary" => []},
      %{
        "type" => "function_call",
        "call_id" => "call_1",
        "name" => "lookup",
        "arguments" => "{}"
      },
      %{"type" => "function_call_output", "call_id" => "call_1", "output" => "found"}
    ]

    body = round_trip(items ++ [%{"type" => "message", "role" => "user", "content" => "next"}])
    assert Enum.take(body["input"], 3) == items

    assert List.last(body["input"]) == %{
             "role" => "user",
             "content" => [%{"type" => "input_text", "text" => "next"}]
           }
  end
end
