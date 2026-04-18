defmodule DodoRouter.Proxy.Adapters.OpenAICompatible do
  @moduledoc """
  Shared implementation for OpenAI-compatible APIs.

  Providers like Groq, Mistral, xAI, DeepSeek, and Cohere all use the same
  OpenAI-style API format with different base URLs.
  """

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.FinchTelemetry
  alias DodoRouter.Routers.RoutingStep

  @timeout_ms 120_000

  def call(request, %RoutingStep{} = step, api_key, base_url, opts \\ []) do
    url = base_url <> "/chat/completions"
    body = build_request_body(request, step)

    headers = build_headers(api_key, opts)
    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()

    case Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: response_body, headers: resp_headers}} ->
        total_ms = latency(start_time)
        upload_ms = FinchTelemetry.get_upload_ms(start_time)
        provider_processing_ms = FinchTelemetry.extract_provider_processing_ms(resp_headers)

        meta = %{
          "ttfb_ms" => total_ms,
          "upload_ms" => upload_ms,
          "payload_size_bytes" => payload_size_bytes,
          "provider_processing_ms" => provider_processing_ms
        }

        {:ok, Map.put(response_body, "_meta", meta)}

      {:ok, %{status: status, body: response_body}} ->
        provider = Keyword.get(opts, :provider, "unknown")
        Logger.error("[#{provider}] Non-200 response: status=#{status} body=#{inspect(response_body)}")
        reason = Adapter.categorize_error(status, response_body)
        {:error, reason, %{status: status, body: response_body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  def stream(request, %RoutingStep{} = step, api_key, send_chunk, base_url, opts \\ []) do
    url = base_url <> "/chat/completions"

    body =
      build_request_body(request, step)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    headers = build_headers(api_key, opts)
    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()
    provider = Keyword.get(opts, :provider, "unknown")
    Process.delete(:"__#{provider}_stream_acc__")

    into_fun = fn {:data, data}, {req, resp} ->
      resp =
        if resp.private[:stream_acc] == nil do
          ttfb = System.monotonic_time(:millisecond) - start_time

          initial_acc = %{
            content: "",
            tool_calls: %{},
            usage: nil,
            finish_reason: nil,
            first_chunk_time: ttfb
          }

          Req.Response.put_private(resp, :stream_acc, initial_acc)
        else
          resp
        end

      acc = resp.private.stream_acc

      case parse_sse_chunk(data) do
        {:chunks, chunks} ->
          send_chunk.(data)
          acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        {:chunks_then_done, chunks} ->
          send_chunk.(data)
          acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
          {:halt, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

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

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc =
          resp.private[:stream_acc] ||
            %{content: "", tool_calls: %{}, usage: nil, finish_reason: nil, first_chunk_time: nil}

        upload_ms = calculate_upload_ms(start_time)
        response_headers = FinchTelemetry.get_response_headers(start_time)
        provider_processing_ms = FinchTelemetry.extract_provider_processing_ms(response_headers)

        timing_meta = %{
          payload_size_bytes: payload_size_bytes,
          upload_ms: upload_ms,
          provider_processing_ms: provider_processing_ms
        }

        {:ok, build_final_response(acc, timing_meta)}

      {:ok, %Req.Response{status: status, body: body}} ->
        reason = Adapter.categorize_error(status, body)
        {:error, reason, %{status: status, body: body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  defp build_request_body(request, step) do
    request
    |> Adapter.sanitize_request()
    |> Map.put("model", step.model)
  end

  defp build_headers(api_key, opts) do
    base = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    extra = Keyword.get(opts, :extra_headers, [])
    base ++ extra
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end

  defp parse_sse_chunk(data) do
    lines =
      data
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      Enum.any?(lines, &(&1 == "data: [DONE]")) ->
        chunks =
          lines
          |> Enum.filter(&String.starts_with?(&1, "data: "))
          |> Enum.reject(&(&1 == "data: [DONE]"))
          |> Enum.map(&parse_data_line/1)
          |> Enum.reject(&is_nil/1)

        if chunks == [], do: :done, else: {:chunks_then_done, chunks}

      true ->
        chunks =
          lines
          |> Enum.filter(&String.starts_with?(&1, "data: "))
          |> Enum.map(&parse_data_line/1)
          |> Enum.reject(&is_nil/1)

        if chunks == [], do: :skip, else: {:chunks, chunks}
    end
  end

  defp parse_data_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, parsed} -> parsed
      {:error, _} -> nil
    end
  end

  defp parse_data_line(_), do: nil

  defp accumulate_chunk(acc, chunk) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}
    finish = get_in(chunk, ["choices", Access.at(0), "finish_reason"])
    usage = chunk["usage"]

    acc
    |> update_content(delta)
    |> update_tool_calls(delta)
    |> maybe_set_finish(finish)
    |> maybe_set_usage(usage)
  end

  defp update_content(acc, %{"content" => content}) when is_binary(content) do
    %{acc | content: acc.content <> content}
  end

  defp update_content(acc, _), do: acc

  defp update_tool_calls(acc, %{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    updated =
      Enum.reduce(tool_calls, acc.tool_calls, fn tc, tools ->
        idx = tc["index"]
        existing = Map.get(tools, idx, %{"id" => nil, "type" => "function", "function" => %{"name" => "", "arguments" => ""}})

        merged = %{
          "id" => tc["id"] || existing["id"],
          "type" => tc["type"] || existing["type"],
          "function" => %{
            "name" => get_in(tc, ["function", "name"]) || get_in(existing, ["function", "name"]) || "",
            "arguments" => (get_in(existing, ["function", "arguments"]) || "") <> (get_in(tc, ["function", "arguments"]) || "")
          }
        }

        Map.put(tools, idx, merged)
      end)

    %{acc | tool_calls: updated}
  end

  defp update_tool_calls(acc, _), do: acc

  defp maybe_set_finish(acc, nil), do: acc
  defp maybe_set_finish(acc, reason), do: %{acc | finish_reason: reason}

  defp maybe_set_usage(acc, nil), do: acc
  defp maybe_set_usage(acc, usage), do: %{acc | usage: usage}

  defp build_final_response(acc, timing_meta) do
    tool_calls_list =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, tc} -> tc end)

    message =
      %{"role" => "assistant", "content" => acc.content}
      |> then(fn m ->
        if tool_calls_list != [], do: Map.put(m, "tool_calls", tool_calls_list), else: m
      end)

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
          "message" => message,
          "finish_reason" => acc.finish_reason
        }
      ],
      "_meta" => meta
    }

    if acc.usage do
      Map.put(response, "usage", acc.usage)
    else
      response
    end
  end
end
