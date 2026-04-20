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

    steps = Routers.list_routing_steps(router)

    if Enum.empty?(steps) do
      {:error, :no_routing_configured}
    else
      # Broadcast request started (shows as pending in logs UI)
      first_step = List.first(steps)
      broadcast_request_started(router, request_id, first_step, streaming)

      result = FallbackChain.execute(request, steps, router.id, opts)

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
  def dispatch_streaming(%Router{} = router, request, send_chunk) do
    dispatch(router, request, stream: true, send_chunk: send_chunk)
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
    request_body = request |> truncate_body() |> Jason.encode!()

    response_body =
      result.final_response |> clean_response() |> truncate_body() |> Jason.encode!()

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
      session_name: session[:session_name]
    }

    Logs.create_log_async(log_attrs)
  end

  defp truncate_body(nil), do: nil

  defp truncate_body(body) when is_map(body) do
    # Truncate message content if too long
    case get_in(body, ["messages"]) do
      messages when is_list(messages) ->
        truncated_messages =
          Enum.map(messages, fn msg ->
            case msg["content"] do
              content when is_binary(content) and byte_size(content) > 1000 ->
                Map.put(msg, "content", String.slice(content, 0, 1000) <> "... [truncated]")

              _ ->
                msg
            end
          end)

        Map.put(body, "messages", truncated_messages)

      _ ->
        body
    end
  end

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
