defmodule DodoRouter.Proxy.Adapters.Zai do
  @moduledoc """
  Adapter for z.ai API (GLM models).

  Supports two base URLs:
  - Standard: https://api.z.ai/api/paas/v4
  - Coding plan: https://api.z.ai/api/coding/paas/v4
  """

  @behaviour DodoRouter.Proxy.Adapter

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Routers.RoutingStep

  @standard_base_url "https://api.z.ai/api/paas/v4"
  @coding_base_url "https://api.z.ai/api/coding/paas/v4"
  @timeout_ms 120_000

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    url = base_url(step) <> "/chat/completions"
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
    url = base_url(step) <> "/chat/completions"
    body = build_request_body(request, step) |> Map.put("stream", true)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    start_time = System.monotonic_time(:millisecond)

    into_fun = fn {:data, data}, {req, resp} ->
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
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        :done ->
          send_chunk.("data: [DONE]\n\n")
          {:halt, {req, resp}}

        :skip ->
          {:cont, {req, resp}}
      end
    end

    case Req.post(url,
           headers: headers,
           json: body,
           receive_timeout: @timeout_ms,
           into: into_fun
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc =
          resp.private[:stream_acc] ||
            %{content: "", usage: nil, finish_reason: nil, first_chunk_time: nil}

        {:ok, build_final_response(acc, start_time)}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        reason = Adapter.categorize_error(status, response_body)
        {:error, reason, %{status: status, body: response_body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  defp base_url(%RoutingStep{plan_type: "coding"}), do: @coding_base_url
  defp base_url(_), do: @standard_base_url

  defp build_request_body(request, %RoutingStep{} = step) do
    # Model always comes from routing step
    # Client values take precedence, step defaults are fallbacks
    request
    |> Map.put("model", step.model)
    |> maybe_default("temperature", step.temperature)
    |> maybe_default("max_tokens", step.max_tokens)
    |> maybe_default("top_p", nil)
    |> maybe_default("frequency_penalty", nil)
    |> maybe_default("presence_penalty", nil)
    |> maybe_default("stop", nil)
  end

  # Only set default if client didn't provide a value
  defp maybe_default(map, _key, nil), do: map
  defp maybe_default(map, key, default) do
    if Map.has_key?(map, key), do: map, else: Map.put(map, key, default)
  end

  defp parse_sse_chunk(data) do
    data
    |> String.split("\n")
    |> Enum.reduce(:skip, fn line, acc ->
      cond do
        String.starts_with?(line, "data: [DONE]") -> :done
        String.starts_with?(line, "data: ") ->
          json = String.trim_leading(line, "data: ")
          case Jason.decode(json) do
            {:ok, parsed} -> {:chunk, parsed}
            _ -> acc
          end
        true -> acc
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

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time
end
