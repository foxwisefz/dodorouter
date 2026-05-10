defmodule DodoRouterWeb.ResponsesFormat do
  @moduledoc """
  Converts between OpenAI Responses API format and OpenAI Chat Completions format.
  """

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
  end

  def from_openai_response(openai_response, request_id) do
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
  end

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

  defp convert_openai_chunk_to_responses_events(chunk, request_id) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}
    content = delta["content"]

    if is_binary(content) and content != "" do
      event_data = %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_#{request_id}",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => content
      }

      ["event: response.output_text.delta\ndata: #{Jason.encode!(event_data)}\n\n"]
    else
      []
    end
  end

  defp convert_input_to_messages(nil), do: []

  defp convert_input_to_messages(input) when is_binary(input) do
    [%{"role" => "user", "content" => input}]
  end

  defp convert_input_to_messages(input) when is_list(input) do
    Enum.map(input, fn
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
