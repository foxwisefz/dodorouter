defmodule DodoRouter.Proxy.FallbackChain do
  @moduledoc """
  Executes routing steps with fallback logic.

  Iterates through steps in order. If a step fails with a fallback-eligible error,
  moves to the next step. Records all attempts for logging.
  """

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouter.Providers
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouter.Secrets

  defstruct [
    :request,
    :steps,
    :router_id,
    :request_id,
    :stream,
    :send_chunk,
    :client_headers,
    :fail_on_context_overflow,
    attempted_steps: [],
    final_response: nil,
    response_headers: nil,
    status: nil,
    partial_content: ""
  ]

  def execute(request, steps, router_id, opts \\ []) do
    stream = Keyword.get(opts, :stream, false)
    send_chunk = Keyword.get(opts, :send_chunk, fn _ -> :ok end)
    client_headers = Keyword.get(opts, :client_headers, [])
    request_id = Keyword.get(opts, :request_id)
    fail_on_context_overflow = Keyword.get(opts, :fail_on_context_overflow, false)

    state = %__MODULE__{
      request: request,
      steps: steps,
      router_id: router_id,
      request_id: request_id,
      stream: stream,
      send_chunk: send_chunk,
      client_headers: client_headers,
      fail_on_context_overflow: fail_on_context_overflow
    }

    run_chain(state)
  end

  defp run_chain(%{steps: []} = state) do
    broadcast_step_completed(state.router_id, nil, :error, nil)
    %{state | status: :error}
  end

  defp run_chain(%{steps: [step | rest]} = state) do
    step_index = length(state.attempted_steps)
    broadcast_step_started(state.router_id, state.request_id, step, step_index)
    start_time = System.monotonic_time(:millisecond)
    endpoint = endpoint_for(step)

    require Logger

    Logger.info(
      "[FallbackChain] Step #{step_index + 1}: #{step.provider}/#{step.model} -> #{endpoint}"
    )

    case execute_step(step, state) do
      {:ok, response, meta} ->
        step_usage = Adapter.extract_usage(response)

        attempt = %{
          provider: step.provider,
          model: step.model,
          endpoint: endpoint,
          plan_type: step.plan_type,
          provider_key_id: key_id_for(step),
          provider_key_label: key_label_for(step),
          provider_key_slug: key_slug_for(step),
          status: "success",
          latency_ms: latency(start_time),
          cache_read_tokens: step_usage.cache_read_tokens,
          cache_write_tokens: step_usage.cache_write_tokens,
          forwarded_headers: build_forwarded_headers(step),
          outbound_headers: meta[:outbound_headers],
          request_body: state.request,
          response_body: response,
          response_headers: meta[:headers]
        }

        status = if length(state.attempted_steps) > 0, do: :fallback, else: :success

        # Prepend any partial content from previous failed attempts
        response = prepend_partial_content(response, state.partial_content)

        final_state = %{
          state
          | final_response: response,
            response_headers: meta[:headers],
            attempted_steps: state.attempted_steps ++ [attempt],
            status: status
        }

        broadcast_step_completed(state.router_id, step, status, latency(start_time))
        final_state

      {:error, reason, details} ->
        # Track midstream fallback info (partial content already sent to client)
        partial_content = details[:partial_content]
        streamed_to_client = details[:chunks_sent] == true and is_binary(partial_content)

        attempt = %{
          provider: step.provider,
          model: step.model,
          endpoint: endpoint,
          plan_type: step.plan_type,
          provider_key_id: key_id_for(step),
          provider_key_label: key_label_for(step),
          provider_key_slug: key_slug_for(step),
          status: "error",
          error: to_string(reason),
          http_status: details[:status],
          error_body:
            truncate_error(details[:body]) ||
              error_body_fallback(reason, details),
          latency_ms: details[:latency_ms] || latency(start_time),
          streamed_to_client: streamed_to_client,
          partial_content_length:
            if(is_binary(partial_content), do: String.length(partial_content), else: nil),
          forwarded_headers: build_forwarded_headers(step),
          outbound_headers: details[:outbound_headers],
          request_body: state.request,
          response_headers: details[:headers]
        }

        state = %{state | attempted_steps: state.attempted_steps ++ [attempt]}

        should_fallback = should_fallback?(reason, length(rest), state.fail_on_context_overflow)

        if should_fallback do
          broadcast_step_completed(state.router_id, step, :fallback, latency(start_time))
          state = accumulate_partial_content(state, details)
          # Reconstruct request with partial assistant message so next provider continues
          state = reconstruct_request(state)
          run_chain(%{state | steps: rest})
        else
          unless Adapter.should_fallback?(reason) do
            require Logger

            Logger.warning(
              "Fallback skipped for #{step.provider}/#{step.model}: " <>
                "error #{inspect(reason)} is not fallback-eligible (remaining steps: #{length(rest)})"
            )
          end

          broadcast_step_completed(state.router_id, step, :error, latency(start_time))
          %{state | status: :error, response_headers: details[:headers]}
        end
    end
  end

  defp broadcast_step_started(router_id, request_id, step, step_index) do
    if step_index > 0 do
      DodoRouter.Activity.step_started(router_id, request_id, step_index)
    end

    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      "router:#{router_id}:events",
      {:step_started,
       %{
         router_id: router_id,
         request_id: request_id,
         step_id: step.id,
         provider: step.provider,
         model: step.model,
         step_index: step_index,
         timestamp: DateTime.utc_now()
       }}
    )
  end

  defp broadcast_step_completed(router_id, step, status, latency_ms) do
    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      "router:#{router_id}:events",
      {:step_completed,
       %{
         router_id: router_id,
         step_id: if(step, do: step.id),
         provider: if(step, do: step.provider),
         model: if(step, do: step.model),
         status: status,
         latency_ms: latency_ms,
         timestamp: DateTime.utc_now()
       }}
    )
  end

  defp execute_step(%RoutingStep{} = step, state) do
    adapter = adapter_for(step.provider)
    api_key = get_api_key(step, state.router_id)

    if is_nil(api_key) do
      {:error, :auth_error, %{status: nil, body: "Missing API key for #{step.provider}"}}
    else
      if state.stream do
        adapter.stream(state.request, step, api_key, state.send_chunk, state.client_headers)
      else
        adapter.call(state.request, step, api_key, state.client_headers)
      end
    end
  end

  defp adapter_for(provider) do
    Registry.adapter_for(provider)
  end

  # Get API key - prefer provider_key if assigned, fall back to legacy router secrets
  defp get_api_key(%RoutingStep{provider_key: %{} = provider_key}, _router_id) do
    Providers.get_raw_api_key(provider_key)
  end

  defp get_api_key(%RoutingStep{provider: "zai"}, router_id) do
    Secrets.zai_api_key(router_id)
  end

  defp get_api_key(%RoutingStep{provider: "moonshot"}, router_id) do
    Secrets.moonshot_api_key(router_id)
  end

  defp get_api_key(_step, _router_id), do: nil

  defp endpoint_for(%RoutingStep{provider: provider} = step) do
    base =
      case Registry.all_adapters()[provider] do
        %{endpoints: endpoints} ->
          # Find the endpoint matching the plan_type, or fall back to first
          key_slug = Registry.to_key_slug(provider, step.plan_type || "standard")
          Map.get(endpoints, key_slug) || endpoints |> Map.values() |> List.first()

        nil ->
          nil
      end

    if base, do: base <> "/chat/completions", else: nil
  end

  @doc false
  def truncate_error(nil), do: nil
  @doc false
  def truncate_error(""), do: nil

  @doc false
  def truncate_error(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, json} when byte_size(json) > 500 -> String.slice(json, 0, 500) <> "..."
      {:ok, json} -> json
      _ -> inspect(body) |> String.slice(0, 500)
    end
  end

  @doc false
  def truncate_error(body), do: inspect(body) |> String.slice(0, 500)

  def error_body_fallback(:timeout, _details), do: "Request timed out"
  def error_body_fallback(:auth_error, %{reason: reason}) when is_binary(reason), do: reason

  def error_body_fallback(reason, details) do
    status = details[:status]
    base = if is_binary(details[:reason]), do: details[:reason], else: to_string(reason)
    if status, do: "HTTP #{status}: #{base}", else: base
  end

  # Accumulate partial content from a failed streaming attempt
  defp accumulate_partial_content(state, %{partial_content: content})
       when is_binary(content) and content != "" do
    %{state | partial_content: state.partial_content <> content}
  end

  defp accumulate_partial_content(state, _details), do: state

  # Reconstruct the request messages to include the partial assistant response
  # so the next provider continues from where the previous one left off
  defp reconstruct_request(%{partial_content: ""} = state), do: state

  defp reconstruct_request(state) do
    request = state.request
    messages = Map.get(request, "messages", [])

    # Append the partial content as an assistant message
    assistant_msg = %{"role" => "assistant", "content" => state.partial_content}
    updated_messages = messages ++ [assistant_msg]

    %{state | request: Map.put(request, "messages", updated_messages)}
  end

  # Prepend partial content from previous attempts to the final response
  defp prepend_partial_content(response, ""), do: response

  defp prepend_partial_content(response, partial) do
    case response do
      %{"choices" => [choice | rest_choices]} ->
        updated_choice =
          update_in(choice, ["message", "content"], fn
            nil -> partial
            existing -> partial <> existing
          end)

        %{response | "choices" => [updated_choice | rest_choices]}

      _ ->
        response
    end
  end

  @doc false
  def should_fallback?(reason, remaining_count, fail_on_context_overflow) do
    Adapter.should_fallback?(reason) and remaining_count > 0 and
      not (reason == :context_overflow and fail_on_context_overflow)
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp key_id_for(%{provider_key: %{id: id}}), do: id
  defp key_id_for(_step), do: nil

  defp key_label_for(%{provider_key: %{label: label}}), do: label
  defp key_label_for(_step), do: nil

  defp key_slug_for(%{provider_key: %{provider_slug: slug}}), do: slug
  defp key_slug_for(_step), do: nil

  defp build_forwarded_headers(_step), do: %{}
end
