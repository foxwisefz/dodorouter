defmodule DodoRouter.Proxy.Adapters.Cohere do
  @moduledoc """
  Adapter for Cohere API.

  Supports Command R and Command R+ models via Cohere's v2 chat endpoint.

  Transformations applied:
  - Maps OpenAI params to Cohere params (top_p → p, n → num_generations, stop → stop_sequences)
  - Transforms response back to OpenAI format
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "cohere",
    display_name: "Cohere",
    key_slugs: ["cohere"],
    endpoints: %{
      "cohere" => "https://api.cohere.com/v2"
    },
    models: ~w(command-r-plus command-r),
    color: "coral",
    short_description: "Command R, R+ models"

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Fidelity
  alias DodoRouter.Proxy.FinchTelemetry
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.cohere.com/v2"
  @timeout_ms 120_000

  @doc """
  Upstream headers: our credentials plus the client's forwardable headers, per
  `Adapter.build_forwarded_headers/2`.
  """
  def request_headers(api_key, client_headers) do
    Adapter.build_forwarded_headers(client_headers, [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ])
  end

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    url = @base_url <> "/chat"
    body = build_cohere_request(request, step)

    headers = request_headers(api_key, client_headers)

    payload_size_bytes = Adapter.record_outbound_body(body)
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
        Logger.error("[Cohere] Non-200 response: status=#{status} body=#{inspect(response_body)}")
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
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    url = @base_url <> "/chat"
    body = build_cohere_request(request, step) |> Map.put("stream", true)

    headers = request_headers(api_key, client_headers)

    payload_size_bytes = Adapter.record_outbound_body(body)
    start_time = FinchTelemetry.mark_request_start()

    into_fun = fn
      {:data, data}, {req, resp} when resp.status != 200 ->
        Adapter.capture_streamed_error({:data, data}, {req, resp})

      {:data, data}, {req, resp} ->
        resp =
          if resp.private[:stream_acc] == nil do
            ttfb = System.monotonic_time(:millisecond) - start_time
            initial_acc = %{content: "", usage: nil, first_chunk_time: ttfb, sse_buffer: ""}
            Req.Response.put_private(resp, :stream_acc, initial_acc)
          else
            resp
          end

        acc = resp.private.stream_acc

        case parse_cohere_sse(data, acc.sse_buffer) do
          {{:events, events}, buffer} ->
            {new_acc, openai_chunks} = process_cohere_events(acc, events)
            Enum.each(openai_chunks, &send_chunk.(&1))
            new_acc = %{new_acc | sse_buffer: buffer}
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, new_acc)}}

          {:done, _buffer} ->
            send_chunk.("data: [DONE]\n\n")
            {:halt, {req, resp}}

          {:skip, buffer} ->
            acc = %{acc | sse_buffer: buffer}
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}
        end
    end

    result =
      Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms, into: into_fun)

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc = resp.private[:stream_acc] || %{content: "", usage: nil, first_chunk_time: nil}

        upload_ms = calculate_upload_ms(start_time)

        timing_meta = %{
          payload_size_bytes: payload_size_bytes,
          upload_ms: upload_ms,
          provider_processing_ms: nil
        }

        {:ok, build_final_response(acc, timing_meta), %{headers: resp.headers}}

      {:ok, %Req.Response{status: status, headers: resp_headers} = resp} ->
        response_body = Adapter.streamed_error_body(resp)
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

  def build_cohere_request(request, step) do
    base =
      request
      |> Adapter.sanitize_request()
      |> Map.put("model", step.model)

    # Map OpenAI params to Cohere params
    base
    |> map_param("top_p", "p")
    |> map_param("n", "num_generations")
    |> map_param("stop", "stop_sequences")
  end

  defp map_param(body, from_key, to_key) do
    case Map.pop(body, from_key) do
      {nil, body} -> body
      {value, body} -> Map.put(body, to_key, value)
    end
  end

  @doc false
  def convert_to_openai_format(cohere_response) do
    message = cohere_response["message"] || %{}
    content_parts = message["content"] || []

    content =
      content_parts
      |> Enum.map(fn part -> part["text"] || "" end)
      |> Enum.join("")

    tool_calls =
      (message["tool_calls"] || [])
      |> Enum.with_index()
      |> Enum.map(fn {tc, idx} ->
        Map.put(tc, "index", idx)
      end)

    openai_message = %{"role" => "assistant", "content" => content}

    openai_message =
      if tool_calls != [],
        do: Map.put(openai_message, "tool_calls", tool_calls),
        else: openai_message

    usage =
      case cohere_response["usage"]["tokens"] do
        %{"input_tokens" => input, "output_tokens" => output} ->
          %{
            "prompt_tokens" => input,
            "completion_tokens" => output,
            "total_tokens" => (input || 0) + (output || 0)
          }

        _ ->
          nil
      end

    response = %{
      "choices" => [%{"index" => 0, "message" => openai_message, "finish_reason" => "stop"}]
    }

    record_untranslated_response(cohere_response)

    if usage, do: Map.put(response, "usage", usage), else: response
  end

  # Consumed above; everything else Cohere returns at the top level — `id`,
  # `finish_reason` (the IR hardcodes "stop"), `logprobs` — has no place in the
  # OpenAI-shaped IR and no Cohere-speaking client to restore it for.
  @translated_response_fields ~w(message usage)

  defp record_untranslated_response(cohere_response) when is_map(cohere_response) do
    cohere_response
    |> Map.drop(@translated_response_fields)
    |> Fidelity.record_dropped_response_fields(
      "no equivalent in the OpenAI Chat Completions format"
    )
  end

  defp record_untranslated_response(_), do: :ok

  defp parse_cohere_sse(data, buffer) do
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
      Enum.any?(events, &(&1["type"] == "message-end")) -> {:done, ""}
      events == [] -> {:skip, buffer}
      true -> {{:events, events}, buffer}
    end
  end

  defp process_cohere_events(acc, events) do
    Enum.reduce(events, {acc, []}, fn event, {acc, chunks} ->
      case event["type"] do
        "content-delta" ->
          text = get_in(event, ["delta", "message", "content", "text"]) || ""
          new_acc = %{acc | content: acc.content <> text}

          if text != "" do
            chunk =
              "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]})}\n\n"

            {new_acc, chunks ++ [chunk]}
          else
            {new_acc, chunks}
          end

        "message-end" ->
          usage = get_in(event, ["delta", "usage", "tokens"])

          new_acc =
            if usage do
              %{
                acc
                | usage: %{
                    "prompt_tokens" => usage["input_tokens"],
                    "completion_tokens" => usage["output_tokens"],
                    "total_tokens" => (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
                  }
              }
            else
              acc
            end

          {new_acc, chunks}

        _ ->
          {acc, chunks}
      end
    end)
  end

  defp build_final_response(acc, timing_meta) do
    meta = %{
      "ttfb_ms" => acc.first_chunk_time,
      "upload_ms" => timing_meta.upload_ms,
      "payload_size_bytes" => timing_meta.payload_size_bytes,
      "provider_processing_ms" => timing_meta.provider_processing_ms
    }

    response = %{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => acc.content},
          "finish_reason" => "stop"
        }
      ],
      "_meta" => meta
    }

    if acc.usage, do: Map.put(response, "usage", acc.usage), else: response
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end
end
