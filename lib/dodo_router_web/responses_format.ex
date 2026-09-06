defmodule DodoRouterWeb.ResponsesFormat do
  @moduledoc """
  Converts between OpenAI Responses API format and OpenAI Chat Completions format.
  """

  # Top-level Responses request fields this module carries into the
  # OpenAI-shaped intermediate representation.
  @consumed_fields ~w(
    model input instructions stream temperature top_p
    max_output_tokens truncation tools tool_choice parallel_tool_calls
    metadata reasoning
  )

  # Injected by the router from the URL path — never part of the client body.
  @ignored_fields ~w(router_slug)

  @doc """
  Top-level fields present in an incoming Responses request that the conversion
  to Chat Completions format does **not** carry.

  See `DodoRouterWeb.AnthropicFormat.unknown_fields/1` — same contract, same
  reason: the conversion is a whitelist, so unrecognised fields vanish
  silently and the client gets a 200 that ignored what it asked for.
  """
  def unknown_fields(responses_params) when is_map(responses_params) do
    responses_params
    |> Map.keys()
    |> Enum.reject(&(&1 in @consumed_fields or &1 in @ignored_fields))
    |> Enum.sort()
  end

  @doc """
  The untranslated fields *with their values*, for a step that speaks the
  Responses format back to us.

  Same contract as `DodoRouterWeb.AnthropicFormat.passthrough_fields/1`: the
  loss is at the IR, not the provider, so a Responses request served by a
  Responses-format adapter should reach the wire whole. `FallbackChain` hands
  this to a step declaring `request_format: :responses` and records it as lost
  against any step that doesn't.

  Safe to merge by construction — these are exactly the keys `@consumed_fields`
  does *not* contain, so it can never carry a stale `model` or `tools` back
  over a routing decision.
  """
  def passthrough_fields(responses_params) when is_map(responses_params) do
    Map.take(responses_params, unknown_fields(responses_params))
  end

  def to_openai_params(responses_params) do
    messages = convert_input_to_messages(responses_params["input"])

    messages =
      case responses_params["instructions"] do
        nil ->
          messages

        instructions when is_binary(instructions) ->
          [%{"role" => "system", "content" => instructions} | messages]
      end

    %{
      "model" => responses_params["model"],
      "messages" => messages
    }
    |> maybe_put("stream", responses_params["stream"])
    |> maybe_put("temperature", responses_params["temperature"])
    |> maybe_put("top_p", responses_params["top_p"])
    |> maybe_put("max_tokens", responses_params["max_output_tokens"])
    |> maybe_put("stop", responses_params["truncation"])
    |> maybe_put("tools", responses_params["tools"])
    |> maybe_put("tool_choice", responses_params["tool_choice"])
    |> maybe_put("parallel_tool_calls", responses_params["parallel_tool_calls"])
    |> maybe_put("metadata", responses_params["metadata"])
    |> maybe_put("reasoning_effort", client_reasoning_effort(responses_params))
  end

  # Preserve the client's requested reasoning effort so it survives the
  # round-trip through the internal chat-completions format. Adapters treat a
  # client-supplied effort as taking precedence over the step default.
  defp client_reasoning_effort(%{"reasoning" => %{"effort" => effort}})
       when is_binary(effort) and effort != "",
       do: effort

  defp client_reasoning_effort(_), do: nil

  def from_openai_response(openai_response, request_id, provider_passthrough \\ %{}) do
    choice = get_in(openai_response, ["choices", Access.at(0)]) || %{}
    message = choice["message"] || %{}
    usage = openai_response["usage"] || %{}
    model = openai_response["model"] || "unknown"

    content_parts = build_content_parts(message)

    output = [
      %{
        "type" => "message",
        "id" => "msg_#{request_id}",
        "role" => "assistant",
        "content" => content_parts
      }
    ]

    output_text =
      content_parts
      |> Enum.filter(&(&1["type"] == "output_text"))
      |> Enum.map_join("", & &1["text"])

    %{
      "id" => "resp_#{request_id}",
      "object" => "response",
      "created_at" => System.system_time(:second),
      "model" => model,
      "status" => "completed",
      "output" => output,
      "usage" => %{
        "input_tokens" => usage["prompt_tokens"] || 0,
        "output_tokens" => usage["completion_tokens"] || 0,
        "total_tokens" => usage["total_tokens"] || 0
      },
      "error" => nil,
      "incomplete_details" => nil,
      "instructions" => nil,
      "max_output_tokens" => nil,
      "output_text" => output_text,
      "parallel_tool_calls" => true,
      "previous_response_id" => nil,
      "reasoning" => %{
        "effort" => nil,
        "summary" => nil
      },
      "temperature" => nil,
      "text" => %{
        "format" => %{
          "type" => "text"
        }
      },
      "tool_choice" => nil,
      "tools" => [],
      "top_p" => nil,
      "truncation" => nil,
      "user" => nil,
      "metadata" => %{}
    }
    |> restore_provider_passthrough(provider_passthrough)
  end

  # When a Responses-format provider served the request, the response never
  # needed translating either. The passthrough wins on collision by design: the
  # fields it overlaps with are ones synthesised above — most of them hardcoded
  # `nil` — and the provider's real values are strictly better. Chief among
  # them the real `resp_…` id, which is what a client needs to chain the next
  # turn with `previous_response_id`.
  defp restore_provider_passthrough(built, passthrough) when map_size(passthrough) == 0, do: built
  defp restore_provider_passthrough(built, passthrough), do: Map.merge(built, passthrough)

  def convert_sse_chunk(openai_sse_data, request_id) when is_binary(openai_sse_data) do
    openai_sse_data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.flat_map(fn json_str ->
      case Jason.decode(json_str) do
        {:ok, chunk} -> convert_openai_chunk_to_responses_events(chunk, request_id)
        _ -> []
      end
    end)
    |> case do
      [] -> :skip
      events -> {:ok, events}
    end
  end

  # Responses API streaming clients (e.g. Codex CLI) track an "active item"
  # client-side and require response.output_item.added + response.content_part.added
  # before the first response.output_text.delta for that item — otherwise they
  # reject the delta as "without active item". Chunks arrive one at a time with
  # no shared accumulator, so item-started/text-so-far state is tracked in the
  # process dictionary, keyed by request_id (each request is handled by a single
  # process, and request_id is unique per request, so this can't collide).
  defp convert_openai_chunk_to_responses_events(chunk, request_id) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}
    content = delta["content"]
    finish_reason = get_in(chunk, ["choices", Access.at(0), "finish_reason"])

    text_events =
      if is_binary(content) and content != "" do
        accumulate_output_text(request_id, content)
        lifecycle_start_events(request_id) ++ [output_text_delta_event(request_id, content)]
      else
        []
      end

    done_events =
      if finish_reason && item_started?(request_id) do
        lifecycle_done_events(request_id)
      else
        []
      end

    text_events ++ done_events
  end

  defp item_started_key(request_id), do: {:responses_item_started, request_id}
  defp output_text_key(request_id), do: {:responses_output_text, request_id}

  defp item_started?(request_id), do: Process.get(item_started_key(request_id), false)

  defp accumulate_output_text(request_id, content) do
    key = output_text_key(request_id)
    Process.put(key, Process.get(key, "") <> content)
  end

  defp output_text_delta_event(request_id, content) do
    event_data = %{
      "type" => "response.output_text.delta",
      "item_id" => "msg_#{request_id}",
      "output_index" => 0,
      "content_index" => 0,
      "delta" => content
    }

    "event: response.output_text.delta\ndata: #{Jason.encode!(event_data)}\n\n"
  end

  defp lifecycle_start_events(request_id) do
    if item_started?(request_id) do
      []
    else
      Process.put(item_started_key(request_id), true)

      item_added = %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "id" => "msg_#{request_id}",
          "status" => "in_progress",
          "role" => "assistant",
          "content" => []
        }
      }

      part_added = %{
        "type" => "response.content_part.added",
        "item_id" => "msg_#{request_id}",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => "", "annotations" => []}
      }

      [
        "event: response.output_item.added\ndata: #{Jason.encode!(item_added)}\n\n",
        "event: response.content_part.added\ndata: #{Jason.encode!(part_added)}\n\n"
      ]
    end
  end

  defp lifecycle_done_events(request_id) do
    full_text = Process.get(output_text_key(request_id), "")
    Process.delete(item_started_key(request_id))
    Process.delete(output_text_key(request_id))

    text_done = %{
      "type" => "response.output_text.done",
      "item_id" => "msg_#{request_id}",
      "output_index" => 0,
      "content_index" => 0,
      "text" => full_text
    }

    part_done = %{
      "type" => "response.content_part.done",
      "item_id" => "msg_#{request_id}",
      "output_index" => 0,
      "content_index" => 0,
      "part" => %{"type" => "output_text", "text" => full_text, "annotations" => []}
    }

    item_done = %{
      "type" => "response.output_item.done",
      "output_index" => 0,
      "item" => %{
        "type" => "message",
        "id" => "msg_#{request_id}",
        "status" => "completed",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => full_text, "annotations" => []}]
      }
    }

    [
      "event: response.output_text.done\ndata: #{Jason.encode!(text_done)}\n\n",
      "event: response.content_part.done\ndata: #{Jason.encode!(part_done)}\n\n",
      "event: response.output_item.done\ndata: #{Jason.encode!(item_done)}\n\n"
    ]
  end

  defp convert_input_to_messages(nil), do: []

  defp convert_input_to_messages(input) when is_binary(input) do
    [%{"role" => "user", "content" => input}]
  end

  defp convert_input_to_messages(input) when is_list(input) do
    Enum.map(input, fn
      # Responses input is a tagged union, not just chat messages. In particular,
      # Codex additional_tools has a role but no content. Preserve opaque items
      # before matching role/content so their type and payload survive the IR.
      %{"type" => type} = item when is_binary(type) and type != "message" ->
        item

      %{"type" => "message", "role" => role, "content" => content} ->
        %{"role" => role, "content" => content}

      %{"role" => role, "content" => content} ->
        %{"role" => role, "content" => content}

      other ->
        other
    end)
  end

  defp build_content_parts(%{"tool_calls" => tool_calls, "content" => content}) do
    text_parts =
      if content not in [nil, ""] do
        [%{"type" => "output_text", "text" => content, "annotations" => []}]
      else
        []
      end

    tool_parts =
      Enum.map(tool_calls, fn tc ->
        %{
          "type" => "tool_call",
          "call_id" => tc["id"],
          "name" => get_in(tc, ["function", "name"]),
          "arguments" => get_in(tc, ["function", "arguments"]) || "{}"
        }
      end)

    text_parts ++ tool_parts
  end

  defp build_content_parts(%{"content" => content}) when is_binary(content) and content != "" do
    [%{"type" => "output_text", "text" => content, "annotations" => []}]
  end

  defp build_content_parts(%{"content" => nil}), do: []
  defp build_content_parts(_), do: []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
