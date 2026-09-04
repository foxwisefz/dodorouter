defmodule DodoRouter.Proxy.FallbackChain do
  @moduledoc """
  Executes routing steps with fallback logic.

  Iterates through steps in order. If a step fails with a fallback-eligible error,
  moves to the next step. Records all attempts for logging.
  """

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouter.Proxy.Fidelity
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
    :on_step_start,
    :client_headers,
    :fail_on_context_overflow,
    :client_format,
    :passthrough_detail,
    passthrough_fields: %{},
    response_passthrough: %{},
    attempted_steps: [],
    final_response: nil,
    response_headers: nil,
    status: nil,
    partial_content: ""
  ]

  def execute(request, steps, router_id, opts \\ []) do
    stream = Keyword.get(opts, :stream, false)
    send_chunk = Keyword.get(opts, :send_chunk, fn _ -> :ok end)

    # Streaming passthrough is only offered while the wire is untouched: once
    # any step has streamed content, a later step must reframe into the
    # message already underway rather than open a second native one. Tracked
    # in the process because adapters run inline in this process and the flag
    # has to flip the moment the first chunk goes out.
    Process.delete(:__chain_wire_touched__)

    # Eval replays wait for the answer they are paying to measure; live
    # traffic fails over. Set unconditionally so a reused process never
    # carries the previous dispatch's deadline.
    Adapter.put_receive_timeout(Keyword.get(opts, :traffic_type))

    send_chunk =
      if stream do
        fn data ->
          Process.put(:__chain_wire_touched__, true)
          send_chunk.(data)
        end
      else
        send_chunk
      end

    on_step_start = Keyword.get(opts, :on_step_start, fn _ -> :ok end)
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
      on_step_start: on_step_start,
      client_headers: client_headers,
      fail_on_context_overflow: fail_on_context_overflow,
      client_format: Keyword.get(opts, :client_format),
      passthrough_fields: Keyword.get(opts, :passthrough_request_fields, %{}),
      passthrough_detail: Keyword.get(opts, :passthrough_detail)
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

    result = execute_step(step, state)
    fidelity = Fidelity.take()
    # Adapters that return it in their own meta still win; this covers the rest.
    outbound_body = Adapter.take_outbound_body()

    case result do
      {:ok, response, meta} ->
        step_usage = Adapter.extract_usage(response)

        attempt = %{
          step_id: step.id,
          position: step.position,
          provider: step.provider,
          model: step.model,
          endpoint: endpoint,
          plan_type: step.plan_type,
          reasoning_effort: step.reasoning_effort,
          temperature: step.temperature,
          max_tokens: step.max_tokens,
          thinking_enabled: step.thinking_enabled,
          provider_key_id: key_id_for(step),
          provider_key_label: key_label_for(step),
          provider_key_slug: key_slug_for(step),
          status: "success",
          latency_ms: latency(start_time),
          cache_read_tokens: step_usage.cache_read_tokens,
          cache_write_tokens: step_usage.cache_write_tokens,
          fidelity_changes: attribute(fidelity, step),
          outbound_headers: meta[:outbound_headers] || fidelity.outbound_headers,
          outbound_body: meta[:outbound_body] || outbound_body,
          request_body: state.request,
          response_body: response,
          response_headers: meta[:headers]
        }

        status = if length(state.attempted_steps) > 0, do: :fallback, else: :success

        # Prepend any partial content from previous failed attempts
        response =
          response
          |> stamp_serving_model(step)
          |> prepend_partial_content(state.partial_content)

        final_state = %{
          state
          | final_response: response,
            response_passthrough: meta[:response_passthrough] || %{},
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
          step_id: step.id,
          position: step.position,
          provider: step.provider,
          model: step.model,
          endpoint: endpoint,
          plan_type: step.plan_type,
          reasoning_effort: step.reasoning_effort,
          temperature: step.temperature,
          max_tokens: step.max_tokens,
          thinking_enabled: step.thinking_enabled,
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
          # The text itself, not just its length: it went to the client but is
          # otherwise recoverable only by slicing the final response, and the
          # Trace shows it on the attempt that actually streamed it.
          partial_content: partial_content,
          partial_content_length:
            if(is_binary(partial_content), do: String.length(partial_content), else: nil),
          fidelity_changes: attribute(fidelity, step),
          outbound_headers: details[:outbound_headers] || fidelity.outbound_headers,
          outbound_body: details[:outbound_body] || outbound_body,
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
      update = %{
        router_id: router_id,
        request_id: request_id,
        provider: step.provider,
        model: step.model,
        plan_type: step.plan_type,
        step_index: step_index,
        timestamp: DateTime.utc_now()
      }

      # The pending row in the logs list was announced with the first step's
      # provider. Without this, a fallback is invisible while the request is
      # in flight — the row keeps naming a provider that already failed until
      # the terminal log replaces it. Activity gets the same update so its
      # stored copy stays true for LiveViews that mount mid-fallback.
      DodoRouter.Activity.step_started(router_id, request_id, step_index, update)

      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router_id}:logs",
        {:log_pending_update, update}
      )
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

    # Adapters record what they strip or rewrite into a per-process buffer as
    # they build the upstream request (see DodoRouter.Proxy.Fidelity). Clearing
    # it here is what keeps step N's record from carrying step N-1's drops.
    Fidelity.reset()
    Adapter.take_outbound_body()

    # Streaming egress needs the serving model *before* the first chunk — an
    # Anthropic `message_start` carries it, and there is no revising it later.
    state.on_step_start.(%{provider: step.provider, model: step.model, position: step.position})

    if is_nil(api_key) do
      {:error, :auth_error, %{status: nil, body: "Missing API key for #{step.provider}"}}
    else
      request =
        state
        |> apply_passthrough(adapter)
        |> apply_stream_passthrough(state, adapter)

      if state.stream do
        adapter.stream(request, step, api_key, state.send_chunk, state.client_headers)
      else
        adapter.call(request, step, api_key, state.client_headers)
      end
      |> split_response_passthrough(state, adapter)
    end
  end

  # The response half of the same rule. What the provider returned that the IR
  # cannot represent is split off the response before anything logs or reads
  # it: handed to the egress when the client speaks the provider's format, and
  # recorded as lost when it doesn't.
  #
  # Runs before `Fidelity.take/0` in `run_chain/1`, so the record lands in this
  # step's buffer like every other per-step change.
  defp split_response_passthrough({:ok, response, meta}, state, adapter) when is_map(response) do
    record_unrepresentable_ir_fields(response, state)

    case Map.pop(response, Adapter.response_passthrough_key()) do
      {fields, response} when is_map(fields) and map_size(fields) > 0 ->
        if Registry.request_format(adapter) == state.client_format do
          {:ok, response, Map.put(meta, :response_passthrough, fields)}
        else
          Fidelity.record_dropped_response_fields(
            fields,
            "the client's format has no place for it"
          )

          {:ok, response, meta}
        end

      {_empty, response} ->
        {:ok, response, meta}
    end
  end

  defp split_response_passthrough(result, _state, _adapter), do: result

  # The egress converters' side of channel 3 (dodo_router-2s4): they run in
  # the controller after the log row's fidelity is harvested, so a field of
  # the IR itself that the client's format cannot carry has to be recorded
  # here, inside the step. Today that is exactly one field — another
  # provider's `reasoning_content`, which neither the Anthropic nor the
  # Responses egress can represent (an unsigned thinking block would be
  # rejected the moment the client echoed it back). OpenAI-format clients
  # receive the IR verbatim, so nothing is lost — and nothing is recorded.
  defp record_unrepresentable_ir_fields(response, %{client_format: format})
       when format in [:anthropic, :responses] do
    case get_in(response, ["choices", Access.at(0), "message", "reasoning_content"]) do
      reasoning when is_binary(reasoning) and reasoning != "" ->
        Fidelity.record_dropped_response_fields(
          %{"reasoning_content" => reasoning},
          "the #{format} egress has no representation for another provider's reasoning text"
        )

      _ ->
        :ok
    end
  end

  defp record_unrepresentable_ir_fields(_response, _state), do: :ok

  # Fields the ingress converter had no translation for. They are lost at the
  # IR, not at the provider — so a step whose adapter speaks the format the
  # client spoke needs no translation and gets them verbatim, and only a step
  # in a different format loses them.
  #
  # Recording that here rather than at the door is what makes the log true per
  # attempt: an Anthropic request served by Anthropic reports nothing, and the
  # same request falling back to an OpenAI-family provider reports the loss
  # against *that* step. Runs after `Fidelity.reset/0` so it lands in this
  # step's buffer.
  defp apply_passthrough(%{passthrough_fields: fields} = state, adapter)
       when map_size(fields) > 0 do
    if Registry.request_format(adapter) == state.client_format do
      Map.put(state.request, Adapter.passthrough_key(), fields)
    else
      Fidelity.record_dropped_body_fields(
        fields,
        :unsupported_by_format_conversion,
        state.passthrough_detail
      )

      state.request
    end
  end

  defp apply_passthrough(state, _adapter), do: state.request

  # An Anthropic client on an Anthropic step gets the provider's native SSE
  # events relayed verbatim — thinking blocks, signatures and server-tool
  # blocks have no representation in the OpenAI reframing (dodo_router-m9w).
  # Only while the wire is untouched: a fallback step after content has
  # streamed must join the message already underway, so it reframes as before.
  # Only the Anthropic adapter implements this today, hence the explicit
  # `:anthropic` rather than bare format equality.
  defp apply_stream_passthrough(request, state, adapter) do
    if state.stream and state.client_format == :anthropic and
         Registry.request_format(adapter) == :anthropic and
         Process.get(:__chain_wire_touched__) != true do
      Map.put(request, Adapter.stream_passthrough_key(), true)
    else
      request
    end
  end

  defp adapter_for(provider) do
    Registry.adapter_for(provider)
  end

  # Get API key - prefer provider_key if assigned, fall back to legacy router secrets
  defp get_api_key(%RoutingStep{provider_key: %{} = provider_key}, _router_id) do
    Providers.resolve_api_key(provider_key)
  end

  defp get_api_key(%RoutingStep{provider: "zai"}, router_id) do
    Secrets.zai_api_key(router_id)
  end

  defp get_api_key(%RoutingStep{provider: "moonshot"}, router_id) do
    Secrets.moonshot_api_key(router_id)
  end

  defp get_api_key(_step, _router_id), do: nil

  defp endpoint_for(%RoutingStep{provider: provider} = step) do
    case Registry.all_adapters()[provider] do
      %{endpoints: endpoints} = config ->
        # Find the endpoint matching the plan_type, or fall back to first
        key_slug = Registry.to_key_slug(provider, step.plan_type || "standard")
        base = Map.get(endpoints, key_slug) || endpoints |> Map.values() |> List.first()

        if base do
          path =
            (config[:endpoint_path] || "/chat/completions")
            |> String.replace("{model}", step.model || "")

          base <> path
        end

      nil ->
        nil
    end
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
    base = describe_reason(reason, details[:reason])
    if status, do: "HTTP #{status}: #{base}", else: base
  end

  # The adapter's own detail wins when it is prose; an exception or atom is
  # named alongside the category rather than dropped, so a transport failure
  # says what the transport saw ("unknown (%Req.TransportError{...}: socket
  # closed)") instead of only which bucket it fell into.
  defp describe_reason(_reason, detail) when is_binary(detail), do: detail
  defp describe_reason(reason, nil), do: to_string(reason)

  defp describe_reason(reason, %{__exception__: true} = exception) do
    "#{reason} (#{inspect(exception)}: #{Exception.message(exception)})"
  end

  defp describe_reason(reason, detail) when is_atom(detail), do: "#{reason} (#{detail})"
  defp describe_reason(reason, detail), do: "#{reason} (#{inspect(detail)})"

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

  # The client must be told which model actually answered, not which one it
  # asked for. Adapters that build a response themselves (every streaming path,
  # and the Anthropic/Google/Cohere format conversions) don't carry `model`, so
  # a silent fallback used to be invisible from the outside — a whole agent
  # session once ran on a different provider unnoticed after a 429. Stamping it
  # here rather than in each adapter means one place to be right, and it is
  # `put_new` so a provider that reports its own resolved model (an alias
  # expanding to a dated snapshot, say) still wins.
  defp stamp_serving_model(response, step) when is_map(response) do
    case response["model"] do
      # A provider naming its own resolved model (an alias expanding to a
      # dated snapshot) wins — but a blank claim is not a claim. "" made
      # clients fall back to the requested model and persist wrong
      # provenance exactly when a fallback step fired (dodo_router-bnn).
      model when is_binary(model) and model != "" -> response
      _blank -> Map.put(response, "model", step.model)
    end
  end

  defp stamp_serving_model(response, _step), do: response

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

  # Header and body policy re-run per step, so a fallback can lose different
  # things than the step it replaced — which is exactly the comparison an
  # operator wants when a retry behaves differently from the original attempt.
  defp attribute(%{changes: []}, _step), do: []

  defp attribute(%{changes: changes}, step),
    do: Fidelity.attribute(changes, step.provider, step.position)
end
