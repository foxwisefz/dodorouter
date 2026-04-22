defmodule DodoRouter.Proxy do
  @moduledoc """
  The Proxy context - dispatches requests through the routing chain.
  """

  alias DodoRouter.Routers
  alias DodoRouter.Routers.Router
  alias DodoRouter.Proxy.{Adapter, FallbackChain}
  alias DodoRouter.Logs

  @doc """
  Dispatches a request through the router's routing chain.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def dispatch(%Router{} = router, request, opts \\ []) do
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
    session = Keyword.get(opts, :session, %{})
    start_time = System.monotonic_time(:millisecond)
    streaming = Keyword.get(opts, :stream, false)
    client_headers = Keyword.get(opts, :client_headers, [])

    steps = Routers.list_routing_steps(router)

    if Enum.empty?(steps) do
      {:error, :no_routing_configured}
    else
      # Broadcast request started (shows as pending in logs UI)
      first_step = List.first(steps)
      broadcast_request_started(router, request_id, first_step, streaming)

      result =
        FallbackChain.execute(
          request,
          steps,
          router.id,
          Keyword.put(opts, :client_headers, client_headers)
        )

      log_request(router, request, result, request_id, start_time, session)
      broadcast_event(router, result)

      # Calculate provider time (sum of all attempt latencies)
      provider_ms = result.attempted_steps |> Enum.map(& &1[:latency_ms]) |> Enum.sum()

      case result.status do
        status when status in [:success, :fallback] ->
          {:ok, result.final_response, %{provider_ms: provider_ms}}

        :error ->
          {:error, :all_providers_failed, result.attempted_steps}
      end
    end
  end

  @doc """
  Dispatches a streaming request.
  """
  def dispatch_streaming(%Router{} = router, request, send_chunk, opts \\ []) do
    dispatch(router, request, Keyword.merge(opts, stream: true, send_chunk: send_chunk))
  end

  defp log_request(router, request, result, request_id, start_time, session) do
    latency_ms = System.monotonic_time(:millisecond) - start_time

    {call_type, tools_invoked} =
      case result.final_response do
        nil -> {"completion", []}
        response -> Adapter.detect_call_type(request, response)
      end

    usage = Adapter.extract_usage(result.final_response || %{})
    last_step = List.last(result.attempted_steps)

    # Encode request/response for storage (truncate large payloads)
    {request_body, req_flags} =
      request |> truncate_body() |> then(&{Jason.encode!(&1), &1[:_truncation_flags] || []})

    {response_body, resp_flags} =
      result.final_response
      |> clean_response()
      |> truncate_body()
      |> then(&{Jason.encode!(&1), &1[:_truncation_flags] || []})

    truncation_flags = req_flags ++ resp_flags

    log_attrs = %{
      router_id: router.id,
      request_id: request_id,
      status: to_string(result.status),
      http_status: if(result.status == :error, do: 502, else: 200),
      attempted_steps: stringify_keys(result.attempted_steps),
      final_provider: last_step[:provider],
      final_model: last_step[:model],
      call_type: call_type,
      tools_invoked: tools_invoked,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      latency_ms: latency_ms,
      ttfb_ms: get_in(result.final_response || %{}, ["_meta", "ttfb_ms"]),
      request_body: request_body,
      response_body: response_body,
      session_id: session[:session_id],
      session_name: session[:session_name],
      truncation_flags: truncation_flags
    }

    Logs.create_log_async(log_attrs)
  end

  defp truncate_body(nil), do: %{"_truncation_flags" => []}

  defp truncate_body(body) when is_map(body) do
    case get_in(body, ["messages"]) do
      messages when is_list(messages) ->
        {truncated_messages, flags} =
          Enum.reduce(messages, {[], []}, fn msg, {acc_msgs, acc_flags} ->
            case msg["content"] do
              content when is_binary(content) ->
                {truncated_content, was_truncated, flag} = smart_truncate(content)

                new_msg =
                  if was_truncated, do: Map.put(msg, "content", truncated_content), else: msg

                new_flags = if flag, do: [flag | acc_flags], else: acc_flags

                {[new_msg | acc_msgs], new_flags}

              _ ->
                {[msg | acc_msgs], acc_flags}
            end
          end)

        body
        |> Map.put("messages", Enum.reverse(truncated_messages))
        |> Map.put("_truncation_flags", Enum.reverse(flags))

      _ ->
        Map.put(body, "_truncation_flags", [])
    end
  end

  defp smart_truncate(content) when is_binary(content) do
    cond do
      # Base64 data: very aggressive truncation
      base64?(content) and byte_size(content) > 1000 ->
        {"[base64 data: #{byte_size(content)} bytes truncated]", true, "request_base64_truncated"}

      # Regular text: generous limit
      byte_size(content) > 50_000 ->
        {String.slice(content, 0, 50_000) <> "\n\n... [truncated]", true,
         "request_text_truncated"}

      true ->
        {content, false, nil}
    end
  end

  defp base64?(content) when is_binary(content) do
    # Base64 strings are typically long with no spaces and only base64 chars
    byte_size(content) > 100 and
      Regex.match?(~r/\A[A-Za-z0-9+\/=]+\z/, content) and
      rem(byte_size(content), 4) == 0
  end

  defp base64?(_), do: false

  defp clean_response(nil), do: nil

  defp clean_response(response) do
    # Remove internal metadata
    Map.delete(response, "_meta")
  end

  # Convert atom keys to string keys for JSON storage
  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_map_keys/1)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp broadcast_request_started(router, request_id, first_step, streaming) do
    pending_log = %{
      id: nil,
      request_id: request_id,
      router: router,
      status: "pending",
      final_provider: first_step.provider,
      final_model: first_step.model,
      streaming: streaming,
      inserted_at: DateTime.utc_now(),
      # Fields needed for display - use string keys to match template expectations
      attempted_steps: [%{"provider" => first_step.provider, "model" => first_step.model}]
    }

    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      "router:#{router.id}:logs",
      {:log_pending, pending_log}
    )
  end

  defp broadcast_event(router, result) do
    last_step = List.last(result.attempted_steps)

    event = %{
      status: result.status,
      provider: last_step[:provider],
      model: last_step[:model],
      latency_ms: last_step[:latency_ms],
      had_fallback: length(result.attempted_steps) > 1,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      "router:#{router.id}:events",
      {:proxy_event, event}
    )
  end
end
