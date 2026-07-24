defmodule DodoRouterWeb.AnthropicFormat do
  @moduledoc """
  Converts between Anthropic Messages API format and OpenAI Chat Completions format.
  """

  def to_openai_params(anthropic_params) do
    raw_messages = anthropic_params["messages"] || []
    converted = convert_messages_to_openai(raw_messages)
    messages = reorder_tool_messages(converted)

    messages =
      case anthropic_params["system"] do
        nil ->
          messages

        system when is_binary(system) ->
          [%{"role" => "system", "content" => system} | messages]

        system when is_list(system) ->
          {text, cache_control} =
            Enum.reduce(system, {"", nil}, fn block, {acc_text, acc_cc} ->
              new_text =
                if block["type"] == "text" do
                  if acc_text == "", do: block["text"], else: acc_text <> "\n" <> block["text"]
                else
                  acc_text
                end

              new_cc = block["cache_control"] || acc_cc
              {new_text, new_cc}
            end)

          if text != "" do
            sys_msg = %{"role" => "system", "content" => text}

            sys_msg =
              if cache_control,
                do: Map.put(sys_msg, "cache_control", cache_control),
                else: sys_msg

            [sys_msg | messages]
          else
            messages
          end
      end

    %{
      "model" => anthropic_params["model"],
      "messages" => messages,
      "max_tokens" => anthropic_params["max_tokens"]
    }
    |> maybe_put("stream", anthropic_params["stream"])
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

    anthropic_usage = %{
      "input_tokens" => usage["prompt_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || 0
    }

    anthropic_usage =
      if usage["cache_read_input_tokens"] || usage["cache_read_tokens"],
        do:
          Map.put(
            anthropic_usage,
            "cache_read_input_tokens",
            usage["cache_read_input_tokens"] || usage["cache_read_tokens"]
          ),
        else: anthropic_usage

    anthropic_usage =
      if usage["cache_creation_input_tokens"] || usage["cache_write_tokens"],
        do:
          Map.put(
            anthropic_usage,
            "cache_creation_input_tokens",
            usage["cache_creation_input_tokens"] || usage["cache_write_tokens"]
          ),
        else: anthropic_usage

    %{
      "id" =>
        "msg_#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.slice(0, 24)}",
      "type" => "message",
      "role" => "assistant",
      "content" => content_blocks,
      "model" => openai_response["model"] || "",
      "stop_reason" => stop_reason,
      "stop_sequence" => nil,
      "usage" => anthropic_usage
    }
  end

  def convert_sse_chunk(openai_sse_data) when is_binary(openai_sse_data) do
    case convert_sse_chunk(openai_sse_data, new_sse_state()) do
      {[], _state} -> :skip
      {events, _state} -> {:ok, events}
    end
  end

  @doc """
  Stateful SSE conversion. `state` (from `new_sse_state/0`) tracks which
  Anthropic content block is open so tool_use blocks get proper
  content_block_start/stop lifecycle events. Block 0 is the text block the
  streaming controller opens up front; each tool call opens the next index.
  """
  def convert_sse_chunk(openai_sse_data, state) when is_binary(openai_sse_data) do
    openai_sse_data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.reduce({[], state}, fn json_str, {events, state} ->
      case Jason.decode(json_str) do
        {:ok, chunk} ->
          {new_events, state} = convert_openai_chunk_to_anthropic_events(chunk, state)
          {events ++ new_events, state}

        _ ->
          {events, state}
      end
    end)
  end

  def new_sse_state, do: %{open_block: 0, tool_blocks: %{}}

  defp convert_openai_chunk_to_anthropic_events(chunk, state) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}
    content = delta["content"]

    text_events =
      if is_binary(content) and content != "" do
        [
          sse_event("content_block_delta", %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => content}
          })
        ]
      else
        []
      end

    {tool_events, state} = convert_tool_call_deltas(delta["tool_calls"], state)
    {text_events ++ tool_events, state}
  end

  defp convert_tool_call_deltas(tool_calls, state) when is_list(tool_calls) do
    Enum.reduce(tool_calls, {[], state}, fn tc, {events, state} ->
      openai_idx = tc["index"] || map_size(state.tool_blocks)

      {start_events, state} =
        if Map.has_key?(state.tool_blocks, openai_idx) do
          {[], state}
        else
          block_idx = map_size(state.tool_blocks) + 1

          stop_event =
            sse_event("content_block_stop", %{
              "type" => "content_block_stop",
              "index" => state.open_block
            })

          start_event =
            sse_event("content_block_start", %{
              "type" => "content_block_start",
              "index" => block_idx,
              "content_block" => %{
                "type" => "tool_use",
                "id" => tc["id"],
                "name" => get_in(tc, ["function", "name"]),
                "input" => %{}
              }
            })

          {[stop_event, start_event],
           %{
             state
             | open_block: block_idx,
               tool_blocks: Map.put(state.tool_blocks, openai_idx, block_idx)
           }}
        end

      args = get_in(tc, ["function", "arguments"])

      json_events =
        if is_binary(args) and args != "" do
          [
            sse_event("content_block_delta", %{
              "type" => "content_block_delta",
              "index" => state.tool_blocks[openai_idx],
              "delta" => %{"type" => "input_json_delta", "partial_json" => args}
            })
          ]
        else
          []
        end

      {events ++ start_events ++ json_events, state}
    end)
  end

  defp convert_tool_call_deltas(_, state), do: {[], state}

  defp sse_event(type, data), do: "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"

  defp convert_messages_to_openai(messages) do
    Enum.flat_map(messages, &convert_message_to_openai/1)
  end

  defp reorder_tool_messages(messages) do
    {result, pending_tools} =
      Enum.reduce(messages, {[], []}, fn msg, {acc, pending} ->
        case msg["role"] do
          "tool" ->
            {acc, pending ++ [msg]}

          _ ->
            {acc ++ pending ++ [msg], []}
        end
      end)

    result ++ pending_tools
  end

  defp convert_message_to_openai(msg) do
    case msg do
      %{"role" => "user", "content" => content} when is_list(content) ->
        {tool_results, other_blocks} = Enum.split_with(content, &(&1["type"] == "tool_result"))

        tool_messages =
          Enum.map(tool_results, fn block ->
            text =
              case block["content"] do
                blocks when is_list(blocks) ->
                  blocks
                  |> Enum.filter(&(&1["type"] == "text"))
                  |> Enum.map(& &1["text"])
                  |> Enum.join("\n")

                text when is_binary(text) ->
                  text

                _ ->
                  ""
              end

            tool_msg = %{
              "role" => "tool",
              "tool_call_id" => block["tool_use_id"],
              "content" => text
            }

            if block["cache_control"],
              do: Map.put(tool_msg, "cache_control", block["cache_control"]),
              else: tool_msg
          end)

        # OpenAI tool messages can't carry images, so images inside
        # tool_result content are surfaced as a user message right after —
        # the Anthropic adapter merges consecutive user messages back into
        # one turn, so they end up alongside the tool_result again.
        tool_result_image_parts =
          tool_results
          |> Enum.flat_map(fn block -> List.wrap(block["content"]) end)
          |> Enum.filter(&is_map/1)
          |> Enum.map(&image_block_to_openai_part/1)
          |> Enum.reject(&is_nil/1)

        tool_image_messages =
          case tool_result_image_parts do
            [] -> []
            parts -> [%{"role" => "user", "content" => parts}]
          end

        # Preserve cache_control from the last text block that has it
        cache_control =
          Enum.find_value(Enum.reverse(other_blocks), fn
            %{"type" => "text", "cache_control" => cc} when cc != nil -> cc
            _ -> nil
          end)

        user_messages =
          case user_content_from_blocks(other_blocks) do
            nil ->
              []

            content ->
              user_msg = %{"role" => "user", "content" => content}

              if cache_control,
                do: [Map.put(user_msg, "cache_control", cache_control)],
                else: [user_msg]
          end

        tool_messages ++ tool_image_messages ++ user_messages

      %{"role" => "user", "content" => content} ->
        msg = %{"role" => "user", "content" => content || ""}

        if msg["cache_control"],
          do: Map.put(msg, "cache_control", msg["cache_control"]),
          else: [msg]

      %{"role" => "assistant", "content" => content} ->
        base_msg = %{"role" => "assistant", "content" => extract_text_from_content(content)}
        tool_use_blocks = extract_tool_use_blocks(content)

        # Preserve cache_control from assistant content blocks
        cache_control =
          if is_list(content) do
            Enum.find_value(Enum.reverse(content), fn
              %{"cache_control" => cc} when cc != nil -> cc
              _ -> nil
            end)
          else
            msg["cache_control"]
          end

        base_msg =
          if cache_control,
            do: Map.put(base_msg, "cache_control", cache_control),
            else: base_msg

        if tool_use_blocks != [] do
          tool_calls =
            Enum.map(tool_use_blocks, fn block ->
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

      %{"role" => "tool_result", "content" => content, "tool_use_id" => id} ->
        text =
          case content do
            blocks when is_list(blocks) ->
              blocks
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map(& &1["text"])
              |> Enum.join("\n")

            text when is_binary(text) ->
              text

            _ ->
              ""
          end

        [%{"role" => "tool", "tool_call_id" => id, "content" => text}]

      %{"role" => role, "content" => content} ->
        [%{"role" => role, "content" => content || ""}]

      _ ->
        []
    end
  end

  # Builds OpenAI user-message content from Anthropic content blocks.
  # Text-only content stays a joined string (the historical shape); as soon as
  # an image is involved the content becomes an OpenAI parts array so the
  # image survives — parts arrays are the intermediate contract adapters
  # already understand (see Adapters.Google.convert_content_parts/1).
  defp user_content_from_blocks(blocks) do
    if Enum.any?(blocks, &(&1["type"] == "image")) do
      parts =
        blocks
        |> Enum.map(fn
          %{"type" => "text", "text" => text} -> %{"type" => "text", "text" => text}
          %{"type" => "image"} = block -> image_block_to_openai_part(block)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      if parts == [], do: nil, else: parts
    else
      case blocks |> Enum.filter(&(&1["type"] == "text")) |> Enum.map(& &1["text"]) do
        [] -> nil
        texts -> Enum.join(texts, "\n")
      end
    end
  end

  defp image_block_to_openai_part(%{
         "type" => "image",
         "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
       }) do
    %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}
  end

  defp image_block_to_openai_part(%{
         "type" => "image",
         "source" => %{"type" => "url", "url" => url}
       }) do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp image_block_to_openai_part(_block), do: nil

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
    text_block =
      if content not in [nil, ""], do: [%{"type" => "text", "text" => content}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn tc ->
        input =
          case Jason.decode(get_in(tc, ["function", "arguments"]) || "{}") do
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
    openai_tools =
      Enum.map(tools, fn tool ->
        openai_tool = %{
          "type" => "function",
          "function" => %{
            "name" => tool["name"],
            "description" => tool["description"] || "",
            "parameters" => tool["input_schema"] || %{"type" => "object", "properties" => %{}}
          }
        }

        if tool["cache_control"],
          do: Map.put(openai_tool, "cache_control", tool["cache_control"]),
          else: openai_tool
      end)

    Map.put(map, "tools", openai_tools)
  end
end
