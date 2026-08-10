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
    start_time = System.monotonic_time(:millisecond)
    streaming = Keyword.get(opts, :stream, false)
    client_headers = Keyword.get(opts, :client_headers, [])

    # Replay and other server-initiated dispatches inject their own steps
    steps = Keyword.get(opts, :steps) || Routers.list_routing_steps(router)

    if Enum.empty?(steps) do
      {:error, :no_routing_configured}
    else
      # Broadcast request started (shows as pending in logs UI)
      first_step = List.first(steps)
      broadcast_request_started(router, request_id, first_step, streaming)

      try do
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

        log = log_request(router, request, result, request_id, start_time, opts)

        record_key_health(result.attempted_steps)

        broadcast_event(router, result, request_id)

        # Calculate provider time (sum of all attempt latencies)
        provider_ms = result.attempted_steps |> Enum.map(& &1[:latency_ms]) |> Enum.sum()

        case result.status do
          status when status in [:success, :fallback] ->
            {:ok, result.final_response, %{provider_ms: provider_ms, log: log}}

          :error ->
            {:error, :all_providers_failed, result.attempted_steps}
        end
      catch
        # A crash mid-chain must still leave an error log row and resolve the
        # pending UI entry before propagating — otherwise the request vanishes
        # from the dashboard entirely.
        kind, reason ->
          stacktrace = __STACKTRACE__
          result = crash_result(kind, reason, stacktrace, first_step)
          log_request(router, request, result, request_id, start_time, opts)
          broadcast_event(router, result, request_id)
          :erlang.raise(kind, reason, stacktrace)
      after
        # Runs on normal return, raise, and throw alike, so the activity count
        # cannot leak when a request dies mid-chain. (Brutal kills skip `after`;
        # Activity's owner monitor covers those.)
        DodoRouter.Activity.request_completed(router.id, request_id)
      end
    end
  end

  # Synthesizes a FallbackChain-shaped result for a request that crashed
  # mid-chain, so log_request/broadcast_event can treat it like a failed attempt.
  defp crash_result(kind, reason, stacktrace, first_step) do
    message =
      case kind do
        :error -> Exception.message(Exception.normalize(:error, reason, stacktrace))
        _ -> inspect(reason)
      end

    %{
      status: :error,
      final_response: nil,
      response_headers: nil,
      attempted_steps: [
        %{
          provider: first_step.provider,
          model: first_step.model,
          error: "exception",
          error_body: message,
          latency_ms: nil
        }
      ]
    }
  end

  @doc """
  Dispatches a streaming request.
  """
  def dispatch_streaming(%Router{} = router, request, send_chunk, opts \\ []) do
    dispatch(router, request, Keyword.merge(opts, stream: true, send_chunk: send_chunk))
  end

  defp log_request(router, request, result, request_id, start_time, opts) do
    session = Keyword.get(opts, :session, %{})
    recording_id = Keyword.get(opts, :recording_id)
    client_headers = Keyword.get(opts, :client_headers, [])
    latency_ms = System.monotonic_time(:millisecond) - start_time

    {call_type, tools_invoked} =
      case result.final_response do
        nil -> {"completion", []}
        response -> Adapter.detect_call_type(request, response)
      end

    usage = Adapter.extract_usage(result.final_response || %{})
    last_step = List.last(result.attempted_steps)

    # Calculate cost using model pricing if available
    %{estimated: estimated_cost, list: list_cost} = calculate_costs(last_step, usage)

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
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
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
      estimated_cost_usd: estimated_cost,
      list_cost_usd: list_cost,
      request_headers: encode_redacted_headers(client_headers),
      response_headers: encode_redacted_headers(result.response_headers),
      replayed_from_id: Keyword.get(opts, :replayed_from_id),
      replay_from_index: Keyword.get(opts, :replay_from_index),
      traffic_type: Keyword.get(opts, :traffic_type, "proxy")
    }

    # :sync callers (e.g. replay) need the persisted row back before returning
    case Keyword.get(opts, :log_mode, :async) do
      :sync ->
        case Logs.create_log(log_attrs) do
          {:ok, log} -> log
          {:error, _changeset} -> nil
        end

      _ ->
        _ = Logs.create_log_async(log_attrs)
        nil
    end
  end

  @doc false
  def build_log_response_body(nil, last_step) do
    last_error = last_step[:error_body]

    cond do
      is_binary(last_error) ->
        case Jason.decode(last_error) do
          {:ok, decoded} when is_map(decoded) -> decoded |> clean_response() |> truncate_body()
          _ -> {%{"_raw_error" => last_error}, []}
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
  # Fire-and-forget key health tracking — must never block or fail dispatch.
  defp record_key_health(attempted_steps) do
    DodoRouter.BackgroundTask.start(DodoRouter.KeyHealthTaskSupervisor, fn ->
      DodoRouter.Providers.record_attempts(attempted_steps)
    end)

    :ok
  rescue
    _ -> :ok
  end

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

              content when is_list(content) ->
                {truncated_parts, part_flags} = truncate_content_parts(content)

                new_msg =
                  if part_flags == [], do: msg, else: Map.put(msg, "content", truncated_parts)

                {[new_msg | acc_msgs], part_flags ++ acc_flags}

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

  # Content parts arrays (multimodal messages) carry base64 images that would
  # otherwise be stored verbatim in request_logs — megabytes per row.
  defp truncate_content_parts(parts) do
    {truncated, flags} =
      Enum.reduce(parts, {[], []}, fn part, {acc_parts, acc_flags} ->
        case part do
          %{"type" => "image_url", "image_url" => %{"url" => "data:" <> _ = url}}
          when byte_size(url) > 1000 ->
            placeholder = "[base64 data: #{byte_size(url)} bytes truncated]"
            new_part = put_in(part, ["image_url", "url"], placeholder)
            {[new_part | acc_parts], ["request_base64_truncated" | acc_flags]}

          %{"type" => "image", "source" => %{"data" => data}} when byte_size(data) > 1000 ->
            placeholder = "[base64 data: #{byte_size(data)} bytes truncated]"
            new_part = put_in(part, ["source", "data"], placeholder)
            {[new_part | acc_parts], ["request_base64_truncated" | acc_flags]}

          %{"type" => "text", "text" => text} when is_binary(text) ->
            {truncated_text, was_truncated, flag} = smart_truncate(text)

            if was_truncated do
              {[Map.put(part, "text", truncated_text) | acc_parts], [flag | acc_flags]}
            else
              {[part | acc_parts], acc_flags}
            end

          _ ->
            {[part | acc_parts], acc_flags}
        end
      end)

    {Enum.reverse(truncated), Enum.reverse(flags)}
  end

  defp smart_truncate(content) when is_binary(content) do
    cond do
      # Base64 data: very aggressive truncation
      base64?(content) and byte_size(content) > 1000 ->
        {"[base64 data: #{byte_size(content)} bytes truncated]", true, "request_base64_truncated"}

      # Regular text: generous limit — coding-agent system prompts routinely
      # run 50-100KB+, so the cap only guards against megabyte-scale pastes.
      byte_size(content) > 200_000 ->
        {String.slice(content, 0, 200_000) <> "\n\n... [truncated]", true,
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
  @doc false
  def stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_map_keys/1)
  end

  @doc false
  def stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_for_json(v)} end)
  end

  # Convert tuple lists (headers) to list-of-lists for JSON serialization
  defp normalize_for_json(list) when is_list(list) do
    Enum.map(list, fn
      {k, v} -> [k, v]
      other -> normalize_for_json(other)
    end)
  end

  defp normalize_for_json(map) when is_map(map) do
    stringify_map_keys(map)
  end

  defp normalize_for_json(value), do: value

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
    |> maybe_truncate_step_field(:outbound_body)
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

  defp maybe_truncate_step_field(step, field) when field in [:request_body, :outbound_body] do
    case Map.get(step, field) do
      nil ->
        step

      body when is_map(body) ->
        {truncated, _flags} = truncate_body(body)
        Map.put(step, field, Jason.encode!(truncated))

      body when is_binary(body) ->
        step
    end
  end

  defp maybe_redact_step_headers(step) do
    step
    |> redact_step_header_field(:response_headers)
    |> redact_step_header_field(:outbound_headers)
  end

  defp redact_step_header_field(step, field) do
    case Map.get(step, field) do
      nil ->
        step

      headers ->
        redacted =
          headers
          |> Redact.redact_headers()
          |> Enum.map(fn {k, v} -> [k, v] end)

        Map.put(step, field, redacted)
    end
  end

  # Subscription surfaces without a models.dev plan catalog: traffic is
  # covered by the flat plan fee, so marginal per-token cost is zero
  @subscription_key_slugs ~w(openai-codex anthropic_oauth)

  # Returns what the request actually cost (`estimated`) and what the same
  # tokens would cost at pay-as-you-go API list prices (`list`). The two
  # coincide for metered keys; they diverge on plan/subscription keys where
  # the marginal cost is zero but the comparison number is not.
  defp calculate_costs(nil, _usage), do: %{estimated: nil, list: nil}

  defp calculate_costs(last_step, usage) do
    key_slug = last_step[:provider_key_slug]
    provider = last_step[:provider]
    model = last_step[:model]

    list =
      case lookup_metered_model(provider, model) do
        nil -> nil
        model_struct -> cost_from_model(model_struct, usage)
      end

    # Plan-specific catalogs (e.g. moonshot_coding, priced $0 — subscription
    # traffic has no marginal per-token cost) win over platform pricing
    plan_row = key_slug != provider && lookup_model(key_slug, model)

    estimated =
      cond do
        match?(%{}, plan_row) -> cost_from_model(plan_row, usage)
        key_slug in @subscription_key_slugs -> Decimal.new(0)
        true -> list
      end

    %{estimated: estimated, list: list}
  end

  defp cost_from_model(model_struct, usage) do
    DodoRouter.Models.calculate_cost(
      model_struct,
      usage.prompt_tokens || 0,
      usage.completion_tokens || 0,
      cache_read_tokens: usage.cache_read_tokens || 0,
      cache_write_tokens: usage.cache_write_tokens || 0
    )
  end

  defp lookup_model(nil, _model), do: nil
  defp lookup_model(_slug, nil), do: nil
  defp lookup_model(slug, model), do: DodoRouter.Models.get_model_by_id(slug, model)

  defp lookup_metered_model(nil, _model), do: nil
  defp lookup_metered_model(_slug, nil), do: nil
  defp lookup_metered_model(slug, model), do: DodoRouter.Models.get_metered_model(slug, model)
end
