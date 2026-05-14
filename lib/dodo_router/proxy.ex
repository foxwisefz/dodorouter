defmodule DodoRouter.Proxy do
  @moduledoc """
  The Proxy context - dispatches requests through the routing chain.
  """

  alias DodoRouter.Routers
  alias DodoRouter.Routers.Router
  alias DodoRouter.Proxy.{Adapter, FallbackChain}
  alias DodoRouter.Logs
  alias DodoRouter.Redact

  @doc """
  Dispatches a request through the router's routing chain.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def dispatch(%Router{} = router, request, opts \\ []) do
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())
    session = Keyword.get(opts, :session, %{})
    recording_id = Keyword.get(opts, :recording_id)
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
          opts
          |> Keyword.put(:client_headers, client_headers)
          |> Keyword.put(:request_id, request_id)
          |> Keyword.put(:fail_on_context_overflow, router.fail_on_context_overflow)
        )

      log_request(
        router,
        request,
        result,
        request_id,
        start_time,
        session,
        recording_id,
        client_headers
      )

      broadcast_event(router, result, request_id)

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

  defp log_request(
         router,
         request,
         result,
         request_id,
         start_time,
         session,
         recording_id,
         client_headers
       ) do
    latency_ms = System.monotonic_time(:millisecond) - start_time

    {call_type, tools_invoked} =
      case result.final_response do
        nil -> {"completion", []}
        response -> Adapter.detect_call_type(request, response)
      end

    usage = Adapter.extract_usage(result.final_response || %{})
    last_step = List.last(result.attempted_steps)

    # Encode request/response for storage (truncate large payloads)
    {truncated_req, req_flags} = truncate_body(request)
    request_body = Jason.encode!(truncated_req)

    {truncated_resp, resp_flags} =
      build_log_response_body(result.final_response, last_step)

    response_body =
      case truncated_resp do
        nil -> "null"
        _ -> Jason.encode!(truncated_resp)
      end

    truncation_flags = req_flags ++ resp_flags

    meta = get_in(result.final_response || %{}, ["_meta"]) || %{}

    log_attrs = %{
      router_id: router.id,
      request_id: request_id,
      status: to_string(result.status),
      http_status: if(result.status == :error, do: 502, else: 200),
      attempted_steps: stringify_keys(truncate_step_responses(result.attempted_steps)),
      final_provider: last_step[:provider],
      final_model: last_step[:model],
      call_type: call_type,
      tools_invoked: tools_invoked,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      latency_ms: latency_ms,
      ttfb_ms: meta["ttfb_ms"],
      upload_ms: meta["upload_ms"],
      payload_size_bytes: meta["payload_size_bytes"],
      provider_processing_ms: meta["provider_processing_ms"],
      request_body: request_body,
      response_body: response_body,
      session_id: session[:session_id],
      session_name: session[:session_name],
      recording_id: recording_id,
      truncation_flags: truncation_flags,
      request_headers: encode_redacted_headers(client_headers),
      response_headers: encode_redacted_headers(result.response_headers)
    }

    Logs.create_log_async(log_attrs)
  end

  @doc false
  def build_log_response_body(nil, last_step) do
    last_error = last_step[:error_body]

    cond do
      is_binary(last_error) ->
        case Jason.decode(last_error) do
          {:ok, decoded} -> decoded |> clean_response() |> truncate_body()
          {:error, _} -> {%{"_raw_error" => last_error}, []}
        end

      is_map(last_error) ->
        last_error |> clean_response() |> truncate_body()

      true ->
        {nil, []}
    end
  end

  def build_log_response_body(response, _last_step) do
    response |> clean_response() |> truncate_body()
  end

  @doc false
  def truncate_body(nil), do: {nil, []}

  def truncate_body(body) when is_map(body) do
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

        body = Map.put(body, "messages", Enum.reverse(truncated_messages))
        {Map.put(body, "_truncation_flags", Enum.reverse(flags)), Enum.reverse(flags)}

      _ ->
        {body, []}
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

  @doc """
  Builds the HTTP status and error response body for a failed sync request.
  Returns a standardized context-overflow error when the last attempt indicates one.
  """
  @spec error_response([map()]) :: {integer(), map()}
  def error_response(attempts) do
    last_attempt = List.last(attempts)

    if last_attempt && last_attempt[:error] == "context_overflow" do
      {400,
       %{
         error: %{
           message: "Input exceeds context window of this model",
           type: "invalid_request_error",
           code: "context_length_exceeded",
           attempts: length(attempts)
         }
       }}
    else
      {502,
       %{
         error: %{
           message: "All providers failed",
           type: "provider_error",
           last_error: last_attempt[:error],
           attempts: length(attempts)
         }
       }}
    end
  end

  @doc """
  Builds the error payload for a failed streaming request.
  """
  @spec streaming_error_payload([map()]) :: map()
  def streaming_error_payload(attempts) do
    last_attempt = List.last(attempts)

    if last_attempt && last_attempt[:error] == "context_overflow" do
      %{
        error: %{
          message: "Input exceeds context window of this model",
          type: "context_overflow"
        }
      }
    else
      %{error: %{message: "All providers failed"}}
    end
  end

  # Convert atom keys to string keys for JSON storage
  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_map_keys/1)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp broadcast_request_started(router, request_id, first_step, streaming) do
    DodoRouter.Activity.request_started(router.id, request_id)

    pending_log = %{
      id: nil,
      request_id: request_id,
      router_id: router.id,
      user_id: router.user_id,
      router: router,
      status: "pending",
      call_type: nil,
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

  defp broadcast_event(router, result, request_id) do
    DodoRouter.Activity.request_completed(router.id, request_id)

    last_step = List.last(result.attempted_steps)

    event = %{
      request_id: request_id,
      router_id: router.id,
      user_id: router.user_id,
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

  defp encode_redacted_headers(nil), do: nil

  defp encode_redacted_headers(headers) do
    headers
    |> Redact.redact_headers()
    |> Enum.map(fn {k, v} -> [k, v] end)
    |> Jason.encode!()
  end

  defp truncate_step_responses(steps) when is_list(steps) do
    Enum.map(steps, &truncate_step_response/1)
  end

  defp truncate_step_response(step) do
    step
    |> maybe_truncate_step_field(:response_body)
    |> maybe_truncate_step_field(:request_body)
    |> maybe_redact_step_headers()
  end

  defp maybe_truncate_step_field(step, :response_body) do
    case Map.get(step, :response_body) do
      nil ->
        step

      body ->
        {truncated, _flags} =
          body
          |> clean_response()
          |> truncate_body()

        Map.put(step, :response_body, Jason.encode!(truncated))
    end
  end

  defp maybe_truncate_step_field(step, :request_body) do
    case Map.get(step, :request_body) do
      nil ->
        step

      body when is_map(body) ->
        {truncated, _flags} = truncate_body(body)
        Map.put(step, :request_body, Jason.encode!(truncated))

      body when is_binary(body) ->
        step
    end
  end

  defp maybe_redact_step_headers(step) do
    case Map.get(step, :response_headers) do
      nil ->
        step

      headers ->
        redacted =
          headers
          |> Redact.redact_headers()
          |> Enum.map(fn {k, v} -> [k, v] end)

        Map.put(step, :response_headers, redacted)
    end
  end
end
