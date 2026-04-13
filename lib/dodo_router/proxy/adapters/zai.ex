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

    # Track partial content in process dict so it survives error paths
    # (Req's into_fun error path loses the resp.private accumulator)
    Process.delete(:__zai_stream_acc__)

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
          Process.put(:__zai_stream_acc__, acc)
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        {:chunks_then_done, chunks} ->
          send_chunk.(data)
          acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
          Process.put(:__zai_stream_acc__, acc)
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

    partial_acc = Process.get(:__zai_stream_acc__)
    Process.delete(:__zai_stream_acc__)

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc =
          resp.private[:stream_acc] ||
            %{content: "", tool_calls: %{}, usage: nil, finish_reason: nil, first_chunk_time: nil}

        {:ok, build_final_response(acc, start_time)}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        reason = Adapter.categorize_error(status, response_body)
        {:error, reason, %{status: status, body: response_body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, build_stream_error_details(partial_acc, start_time)}

      {:error, reason} ->
        {:error, :unknown, build_stream_error_details(partial_acc, start_time, %{reason: reason})}
    end
  end

  @doc false
  def base_url(%RoutingStep{plan_type: "coding"}), do: @coding_base_url
  def base_url(_), do: @standard_base_url

  @doc false
  def build_request_body(request, %RoutingStep{} = step) do
    # Model always comes from routing step
    # Client values take precedence, step defaults are fallbacks
    request
    |> Adapter.sanitize_request()
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

  # Parse SSE data - may contain multiple events batched together
  @doc false
  def parse_sse_chunk(data) do
    lines = String.split(data, "\n")
    has_done = Enum.any?(lines, &String.starts_with?(&1, "data: [DONE]"))

    chunks =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.reject(&String.starts_with?(&1, "data: [DONE]"))
      |> Enum.flat_map(fn line ->
        json = String.trim_leading(line, "data: ")

        case Jason.decode(json) do
          {:ok, parsed} -> [parsed]
          _ -> []
        end
      end)

    cond do
      has_done and chunks == [] -> :done
      has_done -> {:chunks_then_done, chunks}
      chunks == [] -> :skip
      true -> {:chunks, chunks}
    end
  end

  defp accumulate_chunk(acc, chunk_data) do
    content =
      case get_in(chunk_data, ["choices", Access.at(0), "delta", "content"]) do
        nil -> acc.content
        c -> acc.content <> c
      end

    tool_calls = accumulate_tool_calls(acc.tool_calls, chunk_data)
    usage = chunk_data["usage"] || acc.usage

    finish_reason =
      get_in(chunk_data, ["choices", Access.at(0), "finish_reason"]) || acc.finish_reason

    %{acc | content: content, tool_calls: tool_calls, usage: usage, finish_reason: finish_reason}
  end

  @doc false
  def accumulate_tool_calls(existing, chunk_data) do
    case get_in(chunk_data, ["choices", Access.at(0), "delta", "tool_calls"]) do
      nil ->
        existing

      calls when is_list(calls) ->
        Enum.reduce(calls, existing, fn call, acc ->
          index = call["index"] || 0

          case Map.get(acc, index) do
            nil ->
              # First chunk for this tool call - initialize it
              Map.put(acc, index, %{
                "id" => call["id"],
                "type" => call["type"] || "function",
                "function" => %{
                  "name" => get_in(call, ["function", "name"]) || "",
                  "arguments" => get_in(call, ["function", "arguments"]) || ""
                }
              })

            existing_call ->
              # Subsequent chunk - append arguments
              new_args =
                existing_call["function"]["arguments"] <>
                  (get_in(call, ["function", "arguments"]) || "")

              new_name =
                case get_in(call, ["function", "name"]) do
                  nil -> existing_call["function"]["name"]
                  name -> name
                end

              put_in(
                acc,
                [index, "function"],
                %{"name" => new_name, "arguments" => new_args}
              )
          end
        end)
    end
  end

  defp build_final_response(acc, start_time) do
    message = build_final_message(acc)

    %{
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
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

  defp build_final_message(acc) do
    base = %{"role" => "assistant", "content" => acc.content}

    if map_size(acc.tool_calls) > 0 do
      # Convert tool_calls map (keyed by index) to sorted list
      tool_calls_list =
        acc.tool_calls
        |> Enum.sort_by(fn {index, _} -> index end)
        |> Enum.map(fn {_index, call} -> call end)

      Map.put(base, "tool_calls", tool_calls_list)
    else
      base
    end
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
