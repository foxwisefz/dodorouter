defmodule DodoRouter.Proxy.Adapters.Moonshot do
  @moduledoc """
  Adapter for Moonshot AI Kimi API.

  Supports kimi-k2.5 with thinking mode, kimi-k2 series, and moonshot-v1 series.
  """

  @behaviour DodoRouter.Proxy.Adapter

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.moonshot.ai/v1"
  @timeout_ms 120_000

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    url = @base_url <> "/chat/completions"
    body = build_request_body(request, step)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    start_time = System.monotonic_time(:millisecond)

    case Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("[Moonshot] Non-200 response: status=#{status} body=#{inspect(response_body)}")
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
    url = @base_url <> "/chat/completions"

    body =
      build_request_body(request, step)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    start_time = System.monotonic_time(:millisecond)

    # Track partial content in process dict so it survives error paths
    Process.delete(:__moonshot_stream_acc__)
    Process.delete(:__moonshot_raw_body__)

    into_fun = fn {:data, data}, {req, resp} ->
      # Accumulate raw body for error diagnostics
      accumulated = (Process.get(:__moonshot_raw_body__) || "") <> data
      Process.put(:__moonshot_raw_body__, accumulated)

      resp =
        if resp.private[:stream_acc] == nil do
          ttfb = System.monotonic_time(:millisecond) - start_time
          initial_acc = %{content: "", usage: nil, finish_reason: nil, first_chunk_time: ttfb}
          Req.Response.put_private(resp, :stream_acc, initial_acc)
        else
          resp
        end

      acc = resp.private.stream_acc

      case parse_sse_chunk(data) do
        {:chunk, chunk_data} ->
          send_chunk.(data)
          acc = accumulate_chunk(acc, chunk_data)
          Process.put(:__moonshot_stream_acc__, acc)
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        :done ->
          send_chunk.("data: [DONE]\n\n")
          {:halt, {req, resp}}

        :skip ->
          # Could be an error response body that doesn't parse as SSE
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

    partial_acc = Process.get(:__moonshot_stream_acc__)
    raw_body = Process.get(:__moonshot_raw_body__)
    Process.delete(:__moonshot_stream_acc__)
    Process.delete(:__moonshot_raw_body__)

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc =
          resp.private[:stream_acc] ||
            %{content: "", usage: nil, finish_reason: nil, first_chunk_time: nil}

        {:ok, build_final_response(acc, start_time)}

      {:ok, %Req.Response{status: status}} ->
        # Body was consumed by into_fun, use accumulated raw_body instead
        response_body =
          case raw_body do
            nil -> %{"error" => "no body captured"}
            "" -> %{"error" => "empty body"}
            b ->
              case Jason.decode(b) do
                {:ok, decoded} -> decoded
                _ -> %{"raw" => String.slice(b, 0, 500)}
              end
          end

        Logger.error("[Moonshot] Stream error #{status}: #{inspect(response_body)} raw_body_len=#{byte_size(raw_body || "")}")
        reason = Adapter.categorize_error(status, response_body)
        {:error, reason, %{status: status, body: response_body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, build_stream_error_details(partial_acc, start_time)}

      {:error, reason} ->
        {:error, :unknown, build_stream_error_details(partial_acc, start_time, %{reason: reason})}
    end
  end

  defp build_request_body(request, %RoutingStep{} = step) do
    # Model always comes from routing step
    # Client values take precedence, step defaults are fallbacks
    body =
      request
      |> Adapter.sanitize_request()
      |> Map.put("model", step.model)
      |> maybe_default("temperature", step.temperature)
      |> maybe_default("max_tokens", step.max_tokens)
      |> maybe_default("top_p", nil)
      |> maybe_default("frequency_penalty", nil)
      |> maybe_default("presence_penalty", nil)
      |> maybe_default("stop", nil)
      |> maybe_put_thinking(step)

    Logger.info("[Moonshot] Sending request model=#{body["model"]} max_tokens=#{inspect(body["max_tokens"])} msg_count=#{length(body["messages"] || [])} has_tools=#{is_list(body["tools"])}")

    # Log first 2 messages for debugging
    Enum.take(body["messages"] || [], 2)
    |> Enum.with_index()
    |> Enum.each(fn {msg, i} ->
      role = msg["role"]
      content_preview = case msg["content"] do
        c when is_binary(c) -> String.slice(c, 0, 100)
        c -> inspect(c) |> String.slice(0, 100)
      end
      Logger.info("[Moonshot] msg[#{i}] role=#{role} content_type=#{is_binary(msg["content"])} keys=#{inspect(Map.keys(msg))} preview=#{content_preview}")
    end)

    body
  end

  # Only set default if client didn't provide a value
  defp maybe_default(map, _key, nil), do: map

  defp maybe_default(map, key, default) do
    if Map.has_key?(map, key), do: map, else: Map.put(map, key, default)
  end

  defp maybe_put_thinking(body, %RoutingStep{model: "kimi-k2.5", thinking_enabled: enabled})
       when is_boolean(enabled) do
    thinking_type = if enabled, do: "enabled", else: "disabled"
    Map.put(body, "thinking", %{"type" => thinking_type})
  end

  defp maybe_put_thinking(body, _step), do: body

  defp parse_sse_chunk(data) do
    data
    |> String.split("\n")
    |> Enum.reduce(:skip, fn line, acc ->
      cond do
        String.starts_with?(line, "data: [DONE]") ->
          :done

        String.starts_with?(line, "data: ") ->
          json = String.trim_leading(line, "data: ")

          case Jason.decode(json) do
            {:ok, parsed} -> {:chunk, parsed}
            _ -> acc
          end

        true ->
          acc
      end
    end)
  end

  defp accumulate_chunk(acc, chunk_data) do
    content =
      case get_in(chunk_data, ["choices", Access.at(0), "delta", "content"]) do
        nil -> acc.content
        c -> acc.content <> c
      end

    usage = chunk_data["usage"] || acc.usage

    finish_reason =
      get_in(chunk_data, ["choices", Access.at(0), "finish_reason"]) || acc.finish_reason

    %{acc | content: content, usage: usage, finish_reason: finish_reason}
  end

  defp build_final_response(acc, start_time) do
    %{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => acc.content},
          "finish_reason" => acc.finish_reason
        }
      ],
      "usage" => acc.usage,
      "_meta" => %{
        "latency_ms" => latency(start_time),
        "ttfb_ms" => acc.first_chunk_time
      }
    }
  end

  defp build_stream_error_details(partial_acc, start_time, extra \\ %{})

  defp build_stream_error_details(nil, start_time, extra) do
    Map.merge(%{latency_ms: latency(start_time)}, extra)
  end

  defp build_stream_error_details(partial_acc, start_time, extra) do
    Map.merge(
      %{
        latency_ms: latency(start_time),
        partial_content: partial_acc.content,
        chunks_sent: partial_acc.content != ""
      },
      extra
    )
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time
end
