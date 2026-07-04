defmodule DodoRouter.Logs.Provenance do
  @moduledoc """
  Attributes assistant messages in a stored conversation history to the
  session log (and thus provider/model) that produced them.

  Every request in a session replays prior assistant turns verbatim, so a
  turn can be matched back to the sibling log whose response it was.
  Matching is deliberately conservative — exact response content (modulo
  surrounding whitespace) or tool-call ids — so an edited or compacted
  history simply gets no attribution rather than a wrong one.
  """

  alias DodoRouter.Logs.MessageNormalizer

  @doc """
  Annotates assistant messages with a `:producer` map
  (`%{provider, model, log_id}`) when a sibling log's response matches.

  `siblings` need `id`, `final_provider`, `final_model`, `response_body`,
  and `inserted_at` (see `Logs.list_session_responses/2`).
  """
  def annotate(messages, siblings) do
    index = build_index(siblings)

    if map_size(index) == 0 do
      messages
    else
      Enum.map(messages, &annotate_message(&1, index))
    end
  end

  defp annotate_message(%{role: "assistant"} = message, index) do
    case tool_call_hit(index, message) || content_hit(index, message) do
      nil -> message
      producer -> Map.put(message, :producer, producer)
    end
  end

  defp annotate_message(message, _index), do: message

  # Tool-call ids are generated per response, so a match is near-definitive
  defp tool_call_hit(index, %{tool_calls: calls}) when is_list(calls) do
    Enum.find_value(calls, fn
      %{"id" => id} when is_binary(id) -> index[{:tool_call, id}]
      _call -> nil
    end)
  end

  defp tool_call_hit(_index, _message), do: nil

  defp content_hit(index, %{content: content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      trimmed -> index[{:content, trimmed}]
    end
  end

  defp content_hit(_index, _message), do: nil

  defp build_index(siblings) do
    siblings
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.reduce(%{}, fn sibling, index ->
      case MessageNormalizer.parse_response_body(sibling.response_body) do
        nil -> index
        response -> add_response(index, response, producer(sibling))
      end
    end)
  end

  defp producer(sibling) do
    %{
      provider: sibling.final_provider,
      model: sibling.final_model,
      log_id: sibling.id
    }
  end

  defp add_response(index, response, producer) do
    index
    |> add_content_key(response, producer)
    |> add_tool_call_keys(response, producer)
  end

  defp add_content_key(index, %{content: content}, producer) when is_binary(content) do
    case String.trim(content) do
      "" -> index
      trimmed -> Map.put_new(index, {:content, trimmed}, producer)
    end
  end

  defp add_content_key(index, _response, _producer), do: index

  defp add_tool_call_keys(index, %{tool_calls: calls}, producer) when is_list(calls) do
    Enum.reduce(calls, index, fn
      %{"id" => id}, acc when is_binary(id) -> Map.put_new(acc, {:tool_call, id}, producer)
      _call, acc -> acc
    end)
  end

  defp add_tool_call_keys(index, _response, _producer), do: index
end
