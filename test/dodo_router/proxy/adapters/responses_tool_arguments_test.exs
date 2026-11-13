defmodule DodoRouter.Proxy.Adapters.ResponsesToolArgumentsTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.ResponsesAPI
  alias DodoRouterWeb.AnthropicFormat

  test "Codex parallel calls delivered only in done events reach the client exactly once" do
    items =
      Enum.map(0..2, &item(&1, Jason.encode!(%{"city" => Enum.at(~w(Paris London Tokyo), &1)})))

    # Captured from the Codex backend: no function_call_arguments.delta events.
    events =
      Enum.flat_map(items, fn item ->
        [added(item, ""), arguments_done(item), item_done(item)]
      end) ++ [completed(items)]

    {response, choices} = convert(events)
    assert_calls(response, choices, items)
    assert List.last(choices)["finish_reason"] == "tool_calls"
    assert Adapter.extract_usage(response).prompt_tokens == 10

    # The next format converter must receive usable arguments too.
    anthropic = AnthropicFormat.from_openai_response(response)
    tools = Enum.filter(anthropic["content"], &(&1["type"] == "tool_use"))
    assert Enum.map(tools, & &1["input"]) == Enum.map(items, &Jason.decode!(&1["arguments"]))
  end

  test "interleaved delta and done-only calls keep their own arguments without duplication" do
    [first, second, third] =
      items = [
        item(1, ~s({"city":"Paris"})),
        item(4, ~s({"city":"London"})),
        item(6, ~s({"city":"東京"}))
      ]

    events = [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "reasoning", "id" => "rs_0"}
      },
      Map.put(added(first, ""), "output_index", 1),
      Map.put(added(second, ""), "output_index", 4),
      delta(first, ~s({"city":)),
      Map.put(added(third, ""), "output_index", 6),
      delta(third, ~s({"city":"東)),
      Map.put(arguments_done(second), "output_index", 4),
      delta(first, ~s("Paris"})),
      arguments_done(third),
      arguments_done(first),
      item_done(third),
      item_done(second),
      item_done(first),
      completed(items)
    ]

    {response, choices} = convert(events)
    assert_calls(response, choices, items)
  end

  for source <- [:added, :arguments_done, :item_done, :completed] do
    test "recovers arguments supplied in #{source} without argument deltas" do
      tool = item(3, ~s({"city":"Paris"}))

      events =
        case unquote(source) do
          :added -> [added(tool, tool["arguments"]), completed([])]
          :arguments_done -> [added(tool, ""), arguments_done(tool), completed([])]
          :item_done -> [added(tool, ""), item_done(tool), completed([])]
          :completed -> [added(tool, ""), completed([tool])]
        end

      {response, choices} = convert(events)
      assert_calls(response, choices, [tool])
      assert List.last(choices)["finish_reason"] == "tool_calls"
    end
  end

  test "unknown snapshot identities do not attach arguments to an unrelated call" do
    known = item(0, ~s({"city":"Paris"}))

    unknown =
      item(0, ~s({"city":"London"}))
      |> Map.merge(%{"id" => "fc_other", "call_id" => "call_other"})

    events = [added(known, ""), arguments_done(unknown), item_done(unknown), completed([unknown])]
    {response, choices} = convert(events)
    assert_calls(response, choices, [Map.put(known, "arguments", "")])
  end

  test "conflicting snapshots cannot rewrite arguments already sent to the client" do
    tool = item(0, ~s({"city":"Paris"}))
    conflict = Map.put(tool, "arguments", ~s({"city":"London"}))

    events = [
      added(tool, ""),
      delta(tool, tool["arguments"]),
      arguments_done(conflict),
      item_done(conflict),
      completed([conflict])
    ]

    {response, choices} = convert(events)
    assert_calls(response, choices, [tool])
  end

  test "argument snapshots can identify a legacy call by call_id" do
    tool = item(0, "{}") |> Map.delete("id")

    done = %{
      "type" => "response.function_call_arguments.done",
      "call_id" => tool["call_id"],
      "arguments" => "{}"
    }

    {response, choices} = convert([added(tool, ""), done, completed([])])
    assert_calls(response, choices, [tool])
  end

  test "missing identities and non-string snapshots do not fabricate arguments" do
    tool = item(0, "{}")

    events = [
      added(tool, nil),
      %{"type" => "response.function_call_arguments.done", "arguments" => "{}"},
      arguments_done(Map.put(tool, "arguments", %{})),
      item_done(Map.put(tool, "arguments", nil)),
      completed([Map.put(tool, "arguments", [])])
    ]

    {response, choices} = convert(events)
    assert_calls(response, choices, [Map.put(tool, "arguments", "")])
  end

  defp item(index, arguments) do
    %{
      "type" => "function_call",
      "id" => "fc_#{index}",
      "call_id" => "call_#{index}",
      "name" => "get_weather",
      "arguments" => arguments
    }
  end

  defp added(item, arguments),
    do: %{"type" => "response.output_item.added", "item" => Map.put(item, "arguments", arguments)}

  defp item_done(item), do: %{"type" => "response.output_item.done", "item" => item}

  defp arguments_done(item),
    do: %{
      "type" => "response.function_call_arguments.done",
      "item_id" => item["id"],
      "arguments" => item["arguments"]
    }

  defp delta(item, fragment),
    do: %{
      "type" => "response.function_call_arguments.delta",
      "item_id" => item["id"],
      "delta" => fragment
    }

  defp completed(items) do
    %{
      "type" => "response.completed",
      "response" => %{
        "output" => items,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      }
    }
  end

  defp convert(events) do
    initial = %{model: "test", content: "", tool_calls: %{}, usage: nil, finish_reason: nil}

    # Each event may arrive in a different HTTP frame.
    {acc, chunks} =
      Enum.reduce(events, {initial, []}, fn event, {acc, chunks} ->
        {acc, next} = ResponsesAPI.process_events(acc, [event])
        {acc, chunks ++ next}
      end)

    {{:chunks, parsed}, ""} = Adapter.parse_sse_chunk(Enum.join(chunks))
    {ResponsesAPI.build_final_response(acc, %{}), Enum.map(parsed, &hd(&1["choices"]))}
  end

  defp assert_calls(response, choices, items) do
    expected =
      Enum.map(items, fn item ->
        %{
          "id" => item["call_id"],
          "type" => "function",
          "function" => Map.take(item, ["name", "arguments"])
        }
      end)

    assert hd(response["choices"])["message"]["tool_calls"] == expected

    streamed =
      Enum.reduce(choices, %{}, fn choice, acc ->
        Enum.reduce(choice["delta"]["tool_calls"] || [], acc, fn call, acc ->
          function = call["function"]

          Map.update(
            acc,
            call["index"],
            %{
              "id" => call["id"],
              "type" => call["type"],
              "function" => Map.put_new(function, "arguments", "")
            },
            fn existing ->
              update_in(
                existing,
                ["function", "arguments"],
                &(&1 <> (function["arguments"] || ""))
              )
            end
          )
        end)
      end)

    assert streamed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) == expected
  end
end
