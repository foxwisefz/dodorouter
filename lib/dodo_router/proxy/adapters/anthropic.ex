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
    models: ~w(claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-5-sonnet-20241022 claude-3-5-haiku-20241022 claude-3-opus-20240229),
    color: "orange",
    short_description: "Claude Sonnet, Opus, Haiku"

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.anthropic.com/v1"
  @timeout_ms 120_000
  @api_version "2023-06-01"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    url = @base_url <> "/messages"
    body = build_anthropic_request(request, step)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"Content-Type", "application/json"}
    ]

    start_time = System.monotonic_time(:millisecond)

    case Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, convert_to_openai_format(response_body)}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("[Anthropic] Non-200 response: status=#{status} body=#{inspect(response_body)}")
        reason = Adapter.categorize_error(status, response_body)
        {:error, reason, %{status: status, body: response_body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    url = @base_url <> "/messages"
    body = build_anthropic_request(request, step) |> Map.put("stream", true)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"Content-Type", "application/json"}
    ]

    start_time = System.monotonic_time(:millisecond)
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
            first_chunk_time: ttfb
          }

          Req.Response.put_private(resp, :stream_acc, initial_acc)
        else
          resp
        end

      acc = resp.private.stream_acc

      case parse_anthropic_sse(data) do
        {:events, events} ->
          # Convert and forward as OpenAI format
          {acc, openai_chunks} = process_anthropic_events(acc, events)
          Enum.each(openai_chunks, &send_chunk.(&1))
          Process.put(:__anthropic_stream_acc__, acc)
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        :done ->
          send_chunk.("data: [DONE]\n\n")
          {:halt, {req, resp}}

        :skip ->
          {:cont, {req, resp}}
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
        acc = resp.private[:stream_acc] || %{content: "", tool_calls: [], usage: nil, stop_reason: nil, first_chunk_time: nil}
        {:ok, build_final_openai_response(acc, start_time)}

      {:ok, %Req.Response{status: status, body: body}} ->
        reason = Adapter.categorize_error(status, body)
        {:error, reason, %{status: status, body: body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  defp build_anthropic_request(request, step) do
    messages = request["messages"] || []
    {system_msg, other_messages} = extract_system_message(messages)

    anthropic_messages = Enum.map(other_messages, &convert_message_to_anthropic/1)

    body = %{
      "model" => step.model,
      "messages" => anthropic_messages,
      "max_tokens" => request["max_tokens"] || 4096
    }

    body = if system_msg, do: Map.put(body, "system", system_msg), else: body

    # Optional params
    body = if request["temperature"], do: Map.put(body, "temperature", request["temperature"]), else: body
    body = if request["top_p"], do: Map.put(body, "top_p", request["top_p"]), else: body
    body = if request["stop"], do: Map.put(body, "stop_sequences", List.wrap(request["stop"])), else: body

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
      {[], other} -> {nil, other}
      {system_msgs, other} ->
        system_content = system_msgs |> Enum.map(&(&1["content"])) |> Enum.join("\n\n")
        {system_content, other}
    end
  end

  defp convert_message_to_anthropic(%{"role" => "assistant", "tool_calls" => tool_calls} = msg) when is_list(tool_calls) do
    content = [
      if(msg["content"], do: %{"type" => "text", "text" => msg["content"]}, else: nil)
      | Enum.map(tool_calls, fn tc ->
          %{
            "type" => "tool_use",
            "id" => tc["id"],
            "name" => get_in(tc, ["function", "name"]),
            "input" => Jason.decode!(get_in(tc, ["function", "arguments"]) || "{}")
          }
        end)
    ] |> Enum.reject(&is_nil/1)

    %{"role" => "assistant", "content" => content}
  end

  defp convert_message_to_anthropic(%{"role" => "tool", "tool_call_id" => id, "content" => content}) do
    %{
      "role" => "user",
      "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => content}]
    }
  end

  defp convert_message_to_anthropic(%{"role" => role, "content" => content}) do
    %{"role" => role, "content" => content}
  end

  defp convert_tool_to_anthropic(%{"function" => func}) do
    %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{"type" => "object", "properties" => %{}}
    }
  end

  defp convert_to_openai_format(anthropic_response) do
    content_blocks = anthropic_response["content"] || []

    {text_content, tool_calls} =
      Enum.reduce(content_blocks, {"", []}, fn block, {text, tools} ->
        case block["type"] do
          "text" -> {text <> (block["text"] || ""), tools}
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
          _ -> {text, tools}
        end
      end)

    message = %{"role" => "assistant", "content" => text_content}
    message = if tool_calls != [], do: Map.put(message, "tool_calls", tool_calls), else: message

    finish_reason = case anthropic_response["stop_reason"] do
      "end_turn" -> "stop"
      "tool_use" -> "tool_calls"
      "max_tokens" -> "length"
      other -> other
    end

    usage = if anthropic_response["usage"] do
      %{
        "prompt_tokens" => anthropic_response["usage"]["input_tokens"],
        "completion_tokens" => anthropic_response["usage"]["output_tokens"],
        "total_tokens" => (anthropic_response["usage"]["input_tokens"] || 0) + (anthropic_response["usage"]["output_tokens"] || 0)
      }
    end

    response = %{
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]
    }

    if usage, do: Map.put(response, "usage", usage), else: response
  end

  defp parse_anthropic_sse(data) do
    lines = data |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    events =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json ->
        case Jason.decode(json) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      Enum.any?(events, &(&1["type"] == "message_stop")) -> :done
      events == [] -> :skip
      true -> {:events, events}
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
          new_acc = if usage, do: %{new_acc | usage: %{
            "prompt_tokens" => usage["input_tokens"],
            "completion_tokens" => usage["output_tokens"],
            "total_tokens" => (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
          }}, else: new_acc
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

  defp build_final_openai_response(acc, _start_time) do
    message = %{"role" => "assistant", "content" => acc.content}

    finish_reason = case acc.stop_reason do
      "end_turn" -> "stop"
      "tool_use" -> "tool_calls"
      "max_tokens" -> "length"
      other -> other || "stop"
    end

    response = %{
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}],
      "_meta" => %{"ttfb_ms" => acc.first_chunk_time}
    }

    if acc.usage, do: Map.put(response, "usage", acc.usage), else: response
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time
end
