defmodule DodoRouter.Proxy.Adapters.Anthropic do
  @moduledoc """
  Adapter for Anthropic Claude API.

  Converts OpenAI format to Anthropic Messages API format and back.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "anthropic",
    display_name: "Anthropic",
    key_slugs: ["anthropic"],
    endpoints: %{
      "anthropic" => "https://api.anthropic.com/v1"
    },
    models:
      ~w(claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-5-sonnet-20241022 claude-3-5-haiku-20241022 claude-3-opus-20240229),
    color: "orange",
    short_description: "Claude Sonnet, Opus, Haiku"

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.FinchTelemetry
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.anthropic.com/v1"
  @timeout_ms 120_000
  @api_version "2023-06-01"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, _client_headers \\ []) do
    url = @base_url <> "/messages"
    body = build_anthropic_request(request, step)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"Content-Type", "application/json"}
    ]

    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()

    case Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: response_body, headers: resp_headers}} ->
        total_ms = latency(start_time)
        upload_ms = FinchTelemetry.get_upload_ms(start_time)

        meta = %{
          "ttfb_ms" => total_ms,
          "upload_ms" => upload_ms,
          "payload_size_bytes" => payload_size_bytes,
          "provider_processing_ms" => nil
        }

        response = convert_to_openai_format(response_body)
        {:ok, Map.put(response, "_meta", meta), %{headers: resp_headers}}

      {:ok, %{status: status, body: response_body, headers: resp_headers}} ->
        Logger.error(
          "[Anthropic] Non-200 response: status=#{status} body=#{inspect(response_body)}"
        )

        reason = Adapter.categorize_error(status, response_body)

        {:error, reason,
         %{
           status: status,
           body: response_body,
           latency_ms: latency(start_time),
           headers: resp_headers
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, _client_headers \\ []) do
    url = @base_url <> "/messages"
    body = build_anthropic_request(request, step) |> Map.put("stream", true)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"Content-Type", "application/json"}
    ]

    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()
    Process.delete(:__anthropic_stream_acc__)

    into_fun = fn {:data, data}, {req, resp} ->
      resp =
        if resp.private[:stream_acc] == nil do
          ttfb = System.monotonic_time(:millisecond) - start_time

          initial_acc = %{
            content: "",
            tool_calls: [],
            usage: nil,
            stop_reason: nil,
            first_chunk_time: ttfb,
            sse_buffer: ""
          }

          Req.Response.put_private(resp, :stream_acc, initial_acc)
        else
          resp
        end

      acc = resp.private.stream_acc

      case parse_anthropic_sse(data, acc.sse_buffer) do
        {{:events, events}, buffer} ->
          # Convert and forward as OpenAI format
          {acc, openai_chunks} = process_anthropic_events(acc, events)
          Enum.each(openai_chunks, &send_chunk.(&1))
          acc = %{acc | sse_buffer: buffer}
          Process.put(:__anthropic_stream_acc__, acc)
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        {:done, _buffer} ->
          send_chunk.("data: [DONE]\n\n")
          {:halt, {req, resp}}

        {:skip, buffer} ->
          acc = %{acc | sse_buffer: buffer}
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}
      end
    end

    result =
      Req.post(url,
        headers: headers,
        json: body,
        receive_timeout: @timeout_ms,
        into: into_fun
      )

    Process.delete(:__anthropic_stream_acc__)

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc =
          resp.private[:stream_acc] ||
            %{content: "", tool_calls: [], usage: nil, stop_reason: nil, first_chunk_time: nil}

        upload_ms = calculate_upload_ms(start_time)

        timing_meta = %{
          payload_size_bytes: payload_size_bytes,
          upload_ms: upload_ms,
          provider_processing_ms: nil
        }

        {:ok, build_final_openai_response(acc, timing_meta), %{headers: resp.headers}}

      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        reason = Adapter.categorize_error(status, body)

        {:error, reason,
         %{status: status, body: body, latency_ms: latency(start_time), headers: resp_headers}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  def build_anthropic_request(request, step) do
    messages = request["messages"] || []
    {system_msg, system_cache_control, other_messages} = extract_system_message(messages)

    anthropic_messages =
      other_messages
      |> Enum.map(&convert_message_to_anthropic/1)
      |> merge_anthropic_content_blocks()

    body = %{
      "model" => step.model,
      "messages" => anthropic_messages,
      "max_tokens" => request["max_tokens"] || 4096
    }

    body =
      if system_msg do
        system_block = %{"type" => "text", "text" => system_msg}

        system_block =
          if system_cache_control do
            Map.put(system_block, "cache_control", system_cache_control)
          else
            system_block
          end

        Map.put(body, "system", [system_block])
      else
        body
      end

    # Optional params
    body =
      if request["temperature"],
        do: Map.put(body, "temperature", request["temperature"]),
        else: body

    body = if request["top_p"], do: Map.put(body, "top_p", request["top_p"]), else: body

    body =
      if request["stop"],
        do: Map.put(body, "stop_sequences", List.wrap(request["stop"])),
        else: body

    # Forward a client-supplied thinking block (if any) so it takes precedence
    # over the step-level default below.
    body =
      if request["thinking"],
        do: Map.put(body, "thinking", request["thinking"]),
        else: body

    body = Adapter.inject_reasoning_effort(body, step.reasoning_effort, :anthropic)

    # Tools
    if request["tools"] do
      anthropic_tools = Enum.map(request["tools"], &convert_tool_to_anthropic/1)
      Map.put(body, "tools", anthropic_tools)
    else
      body
    end
  end

  defp extract_system_message(messages) do
    case Enum.split_with(messages, &(&1["role"] == "system")) do
      {[], other} ->
        {nil, nil, other}

      {system_msgs, other} ->
        system_content = system_msgs |> Enum.map(& &1["content"]) |> Enum.join("\n\n")

        # Preserve cache_control from the last system message that has it
        cache_control =
          Enum.find_value(Enum.reverse(system_msgs), fn
            %{"cache_control" => cc} when cc != nil -> cc
            _ -> nil
          end)

        {system_content, cache_control, other}
    end
  end

  defp convert_message_to_anthropic(%{"role" => "assistant", "tool_calls" => tool_calls} = msg)
       when is_list(tool_calls) do
    content =
      [
        if(msg["content"] not in [nil, ""],
          do: %{"type" => "text", "text" => msg["content"]},
          else: nil
        )
        | Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => get_in(tc, ["function", "name"]),
              "input" =>
                case Jason.decode(get_in(tc, ["function", "arguments"]) || "{}") do
                  {:ok, decoded} -> decoded
                  _ -> %{}
                end
            }
          end)
      ]
      |> Enum.reject(&is_nil/1)

    content = if content == [], do: [%{"type" => "text", "text" => " "}], else: content

    # Add cache_control to last content block if present
    content =
      if msg["cache_control"] do
        List.update_at(content, -1, &Map.put(&1, "cache_control", msg["cache_control"]))
      else
        content
      end

    %{"role" => "assistant", "content" => content}
  end

  defp convert_message_to_anthropic(
         %{
           "role" => "tool",
           "tool_call_id" => id,
           "content" => content
         } = msg
       ) do
    block = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => content
    }

    block =
      if msg["cache_control"],
        do: Map.put(block, "cache_control", msg["cache_control"]),
        else: block

    %{"role" => "user", "content" => [block]}
  end

  defp convert_message_to_anthropic(%{"role" => role, "content" => content} = msg) do
    if msg["cache_control"] do
      content_blocks =
        if is_binary(content) do
          [%{"type" => "text", "text" => content || " "} | []]
        else
          content
        end

      content_blocks =
        List.update_at(content_blocks, -1, &Map.put(&1, "cache_control", msg["cache_control"]))

      %{"role" => role, "content" => content_blocks}
    else
      %{"role" => role, "content" => content}
    end
  end

  defp convert_tool_to_anthropic(%{"function" => func} = tool) do
    anthropic_tool = %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{"type" => "object", "properties" => %{}}
    }

    if tool["cache_control"],
      do: Map.put(anthropic_tool, "cache_control", tool["cache_control"]),
      else: anthropic_tool
  end

  defp merge_anthropic_content_blocks(messages) when is_list(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [prev | rest] ->
          if prev["role"] == msg["role"] and is_list(prev["content"]) and is_list(msg["content"]) do
            merged_content = prev["content"] ++ msg["content"]
            [Map.put(prev, "content", merged_content) | rest]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  @doc false
  def convert_to_openai_format(anthropic_response) do
    content_blocks = anthropic_response["content"] || []

    {text_content, tool_calls} =
      Enum.reduce(content_blocks, {"", []}, fn block, {text, tools} ->
        case block["type"] do
          "text" ->
            {text <> (block["text"] || ""), tools}

          "tool_use" ->
            tool_call = %{
              "id" => block["id"],
              "type" => "function",
              "function" => %{
                "name" => block["name"],
                "arguments" => Jason.encode!(block["input"] || %{})
              }
            }

            {text, tools ++ [tool_call]}

          _ ->
            {text, tools}
        end
      end)

    message = %{"role" => "assistant", "content" => text_content}
    message = if tool_calls != [], do: Map.put(message, "tool_calls", tool_calls), else: message

    finish_reason =
      case anthropic_response["stop_reason"] do
        "end_turn" -> "stop"
        "tool_use" -> "tool_calls"
        "max_tokens" -> "length"
        other -> other
      end

    usage =
      if anthropic_response["usage"] do
        cache_read = anthropic_response["usage"]["cache_read_input_tokens"]
        cache_write = anthropic_response["usage"]["cache_creation_input_tokens"]

        base = %{
          "prompt_tokens" => anthropic_response["usage"]["input_tokens"],
          "completion_tokens" => anthropic_response["usage"]["output_tokens"],
          "total_tokens" =>
            (anthropic_response["usage"]["input_tokens"] || 0) +
              (anthropic_response["usage"]["output_tokens"] || 0)
        }

        base =
          if cache_read,
            do: Map.put(base, "cache_read_tokens", cache_read),
            else: base

        if cache_write,
          do: Map.put(base, "cache_write_tokens", cache_write),
          else: base
      end

    response = %{
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]
    }

    if usage, do: Map.put(response, "usage", usage), else: response
  end

  defp parse_anthropic_sse(data, buffer) do
    combined = buffer <> data
    lines = String.split(combined, "\n")

    {complete_lines, buffer} =
      case List.last(lines) do
        "" -> {Enum.drop(lines, -1), ""}
        last when byte_size(last) > 0 -> {Enum.drop(lines, -1), last}
      end

    complete_lines = complete_lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    events =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json ->
        case Jason.decode(json) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      Enum.any?(events, &(&1["type"] == "message_stop")) -> {:done, ""}
      events == [] -> {:skip, buffer}
      true -> {{:events, events}, buffer}
    end
  end

  defp process_anthropic_events(acc, events) do
    Enum.reduce(events, {acc, []}, fn event, {acc, chunks} ->
      case event["type"] do
        "content_block_delta" ->
          delta = event["delta"]

          case delta["type"] do
            "text_delta" ->
              new_acc = %{acc | content: acc.content <> (delta["text"] || "")}
              chunk = build_openai_stream_chunk(%{"content" => delta["text"]})
              {new_acc, chunks ++ [chunk]}

            _ ->
              {acc, chunks}
          end

        "message_delta" ->
          new_acc = %{acc | stop_reason: event["delta"]["stop_reason"]}
          usage = event["usage"]

          new_acc =
            if usage do
              cache_read = usage["cache_read_input_tokens"]
              cache_write = usage["cache_creation_input_tokens"]

              base = %{
                "prompt_tokens" =>
                  usage["input_tokens"] || (acc.usage && acc.usage["prompt_tokens"]),
                "completion_tokens" =>
                  usage["output_tokens"] || (acc.usage && acc.usage["completion_tokens"]),
                "total_tokens" =>
                  (usage["input_tokens"] || (acc.usage && acc.usage["prompt_tokens"]) || 0) +
                    (usage["output_tokens"] || (acc.usage && acc.usage["completion_tokens"]) || 0)
              }

              # Preserve cache fields from previous chunk if new ones aren't provided
              base =
                cond do
                  cache_read ->
                    Map.put(base, "cache_read_tokens", cache_read)

                  acc.usage && acc.usage["cache_read_tokens"] ->
                    Map.put(base, "cache_read_tokens", acc.usage["cache_read_tokens"])

                  true ->
                    base
                end

              base =
                cond do
                  cache_write ->
                    Map.put(base, "cache_write_tokens", cache_write)

                  acc.usage && acc.usage["cache_write_tokens"] ->
                    Map.put(base, "cache_write_tokens", acc.usage["cache_write_tokens"])

                  true ->
                    base
                end

              %{new_acc | usage: base}
            else
              new_acc
            end

          {new_acc, chunks}

        _ ->
          {acc, chunks}
      end
    end)
  end

  defp build_openai_stream_chunk(delta) do
    chunk = %{
      "choices" => [%{"index" => 0, "delta" => delta}]
    }

    "data: #{Jason.encode!(chunk)}\n\n"
  end

  defp build_final_openai_response(acc, timing_meta) do
    message = %{"role" => "assistant", "content" => acc.content}

    finish_reason =
      case acc.stop_reason do
        "end_turn" -> "stop"
        "tool_use" -> "tool_calls"
        "max_tokens" -> "length"
        other -> other || "stop"
      end

    meta = %{
      "ttfb_ms" => acc.first_chunk_time,
      "upload_ms" => timing_meta.upload_ms,
      "payload_size_bytes" => timing_meta.payload_size_bytes,
      "provider_processing_ms" => timing_meta.provider_processing_ms
    }

    response = %{
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}],
      "_meta" => meta
    }

    if acc.usage, do: Map.put(response, "usage", acc.usage), else: response
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end
end
