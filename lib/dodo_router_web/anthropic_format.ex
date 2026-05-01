defmodule DodoRouterWeb.AnthropicFormat do
  @moduledoc """
  Converts between Anthropic Messages API format and OpenAI Chat Completions format.
  """

  def to_openai_params(anthropic_params) do
    messages = convert_messages_to_openai(anthropic_params["messages"] || [])

    messages =
      case anthropic_params["system"] do
        nil -> messages
        system when is_binary(system) -> [%{"role" => "system", "content" => system} | messages]
        system when is_list(system) ->
          text = system
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map(& &1["text"])
            |> Enum.join("\n")
          if text != "", do: [%{"role" => "system", "content" => text} | messages], else: messages
      end

    %{
      "model" => anthropic_params["model"],
      "messages" => messages,
      "max_tokens" => anthropic_params["max_tokens"],
      "stream" => anthropic_params["stream"]
    }
    |> maybe_put("temperature", anthropic_params["temperature"])
    |> maybe_put("top_p", anthropic_params["top_p"])
    |> maybe_put("stop", anthropic_params["stop_sequences"])
    |> maybe_put_tools(anthropic_params["tools"])
  end

  def from_openai_response(openai_response) do
    choice = get_in(openai_response, ["choices", Access.at(0)]) || %{}
    message = choice["message"] || %{}
    content_blocks = build_content_blocks(message)
    stop_reason = convert_stop_reason(choice["finish_reason"])
    usage = openai_response["usage"] || %{}

    %{
      "id" => "msg_#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.slice(0, 24)}",
      "type" => "message",
      "role" => "assistant",
      "content" => content_blocks,
      "model" => openai_response["model"] || "",
      "stop_reason" => stop_reason,
      "stop_sequence" => nil,
      "usage" => %{
        "input_tokens" => usage["prompt_tokens"] || 0,
        "output_tokens" => usage["completion_tokens"] || 0
      }
    }
  end

  def convert_sse_chunk(openai_sse_data) when is_binary(openai_sse_data) do
    openai_sse_data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.flat_map(fn json_str ->
      case Jason.decode(json_str) do
        {:ok, chunk} -> convert_openai_chunk_to_anthropic_events(chunk)
        _ -> []
      end
    end)
    |> case do
      [] -> :skip
      events -> {:ok, events}
    end
  end

  defp convert_openai_chunk_to_anthropic_events(chunk) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}
    content = delta["content"]

    if is_binary(content) and content != "" do
      event_data = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => content}
      }

      ["event: content_block_delta\ndata: #{Jason.encode!(event_data)}\n\n"]
    else
      []
    end
  end

  defp convert_messages_to_openai(messages) do
    Enum.flat_map(messages, &convert_message_to_openai/1)
  end

  defp convert_message_to_openai(%{"role" => "user", "content" => content} = msg) do
    case content do
      content when is_list(content) ->
        converted = convert_anthropic_content_blocks(content)
        if converted != [], do: [%{"role" => "user", "content" => converted}], else: []

      _ ->
        [%{"role" => "user", "content" => content || ""}]
    end
    |> maybe_prepend_cache_control(msg)
  end

  defp convert_message_to_openai(%{"role" => "assistant", "content" => content} = msg) do
    base_msg = %{"role" => "assistant", "content" => extract_text_from_content(content)}

    tool_use_blocks = extract_tool_use_blocks(content)

    if tool_use_blocks != [] do
      tool_calls = Enum.map(tool_use_blocks, fn block ->
        %{
          "id" => block["id"],
          "type" => "function",
          "function" => %{
            "name" => block["name"],
            "arguments" => Jason.encode!(block["input"] || %{})
          }
        }
      end)

      [Map.put(base_msg, "tool_calls", tool_calls)]
    else
      [base_msg]
    end
    |> maybe_prepend_cache_control(msg)
  end

  defp convert_message_to_openai(%{"role" => "tool_result", "content" => content, "tool_use_id" => id} = msg) do
    text = case content do
      content when is_list(content) ->
        content
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map(& &1["text"])
        |> Enum.join("\n")

      text when is_binary(text) -> text
      _ -> ""
    end

    [%{"role" => "tool", "tool_call_id" => id, "content" => text}]
    |> maybe_prepend_cache_control(msg)
  end

  defp convert_message_to_openai(%{"role" => role, "content" => content}) do
    [%{"role" => role, "content" => content || ""}]
  end

  defp convert_message_to_openai(_msg), do: []

  defp convert_anthropic_content_blocks(blocks) do
    text_parts = blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    case text_parts do
      [] -> []
      parts -> [%{"type" => "text", "text" => Enum.join(parts, "\n")}]
    end
  end

  defp extract_text_from_content(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.join("")
  end

  defp extract_text_from_content(content), do: content || ""

  defp extract_tool_use_blocks(content) when is_list(content) do
    Enum.filter(content, &(&1["type"] == "tool_use"))
  end

  defp extract_tool_use_blocks(_), do: []

  defp build_content_blocks(%{"tool_calls" => tool_calls, "content" => content}) do
    text_block = if content not in [nil, ""], do: [%{"type" => "text", "text" => content}], else: []

    tool_blocks = Enum.map(tool_calls, fn tc ->
      input = case Jason.decode(get_in(tc, ["function", "arguments"]) || "{}") do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

      %{
        "type" => "tool_use",
        "id" => tc["id"],
        "name" => get_in(tc, ["function", "name"]),
        "input" => input
      }
    end)

    text_block ++ tool_blocks
  end

  defp build_content_blocks(%{"content" => content}) when is_binary(content) and content != "" do
    [%{"type" => "text", "text" => content}]
  end

  defp build_content_blocks(%{"content" => nil}), do: [%{"type" => "text", "text" => ""}]
  defp build_content_blocks(_), do: [%{"type" => "text", "text" => ""}]

  defp convert_stop_reason("stop"), do: "end_turn"
  defp convert_stop_reason("tool_calls"), do: "tool_use"
  defp convert_stop_reason("length"), do: "max_tokens"
  defp convert_stop_reason(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tools(map, nil), do: map
  defp maybe_put_tools(map, tools) do
    openai_tools = Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool["name"],
          "description" => tool["description"] || "",
          "parameters" => tool["input_schema"] || %{"type" => "object", "properties" => %{}}
        }
      }
    end)
    Map.put(map, "tools", openai_tools)
  end

  defp maybe_prepend_cache_control(messages, %{"cache_control" => _} = _msg) do
    messages
  end
  defp maybe_prepend_cache_control(messages, _msg), do: messages
end
