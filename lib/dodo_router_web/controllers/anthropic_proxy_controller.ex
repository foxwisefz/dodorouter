defmodule DodoRouterWeb.AnthropicProxyController do
  use DodoRouterWeb, :controller

  require Logger

  alias DodoRouter.Proxy
  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.Anthropic, as: AnthropicAdapter
  alias DodoRouterWeb.AnthropicFormat

  def create(conn, merged_params) do
    # The BODY, not Phoenix's merged params. An action's `params` is path +
    # query + body, so `POST /v1/messages?beta=true` arrives indistinguishable
    # from a body field named "beta" — and the conversion then forwards it to
    # Anthropic, which rejects unknown top-level body fields. `router_slug` is
    # already listed in AnthropicFormat's @ignored_fields for this same reason;
    # reading the body directly fixes the class instead of naming its members.
    params = request_body(conn, merged_params)
    router = conn.assigns.current_router
    request_id = Ecto.UUID.generate()
    session = extract_session(conn)
    recording_id = extract_active_recording_id(router)
    client_headers = conn.req_headers

    openai_params = AnthropicFormat.to_openai_params(params)

    Logger.info(
      "[AnthropicProxy] request_id=#{request_id} router=#{router.slug} stream=#{params["stream"]} " <>
        "model=#{params["model"]} msg_count=#{length(params["messages"] || [])}"
    )

    untranslated = warn_untranslated(params, request_id, router)

    if params["stream"] == true do
      stream_anthropic(
        conn,
        router,
        openai_params,
        request_id,
        session,
        client_headers,
        recording_id,
        untranslated
      )
    else
      sync_anthropic(
        conn,
        router,
        openai_params,
        request_id,
        session,
        recording_id,
        client_headers,
        untranslated
      )
    end
  end

  # Claude Code paces itself off `anthropic-ratelimit-unified-*`; swallowing
  # those headers means the client flies blind and keeps hammering into a 429
  # it could have waited out. They describe whichever provider actually served
  # the request — which is the honest answer, and the only one we have.
  @forwarded_response_prefixes ~w(anthropic-ratelimit-)

  defp forward_ratelimit_headers(conn, nil), do: conn

  defp forward_ratelimit_headers(conn, headers) do
    headers
    |> normalize_response_headers()
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, @forwarded_response_prefixes) end)
    |> Enum.reduce(conn, fn {key, value}, acc -> put_resp_header(acc, key, value) end)
  end

  # Req hands back a map of name => [values]; Finch a list of tuples.
  defp normalize_response_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn
      {key, [value | _]} -> [{String.downcase(key), to_string(value)}]
      {key, value} when is_binary(value) -> [{String.downcase(key), value}]
      _ -> []
    end)
  end

  defp normalize_response_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} when is_binary(value) -> [{String.downcase(to_string(key)), value}]
      _ -> []
    end)
  end

  defp normalize_response_headers(_), do: []

  # Fields the IR cannot carry travel *with* the request rather than being
  # dropped at the door: a step that speaks Anthropic back to us needs no
  # translation, so it gets them verbatim, and only a step in another format
  # reports them as lost (see `FallbackChain.apply_passthrough/3`). That is
  # also why the record lands per-step instead of "before routing" — whether
  # anything was actually lost depends on which provider answered.
  # Plug.Parsers populates body_params for JSON; anything else (an unparsed or
  # empty body) falls back to the merged params rather than losing the request.
  defp request_body(%{body_params: %{} = body}, _merged) when not is_struct(body), do: body
  defp request_body(_conn, merged), do: merged

  # Plug.Parsers populates body_params for JSON; anything else (an unparsed or
  # empty body) falls back to the merged params rather than losing the request.
  defp request_body(%{body_params: %{} = body}, _merged) when not is_struct(body), do: body
  defp request_body(_conn, merged), do: merged

  # Reading the body directly (dodo_router-b3l) stopped query parameters from
  # masquerading as body fields — and also stopped them travelling at all.
  # Probed 2026-08-16: Anthropic's `?beta=true` changes nothing when the
  # anthropic-beta header is forwarded, so they stay dropped — but recorded,
  # because a loss channel without a record decays into folklore
  # (dodo_router-69m).
  defp dropped_query_params(conn) do
    Plug.Conn.fetch_query_params(conn).query_params
  end

  # `client_format` is always declared, not only when untranslated fields
  # exist: the response-direction passthrough (native content blocks, real
  # message ids, streaming passthrough) keys off it for every request, and
  # tying it to the request-side leftovers silently disabled all of that for
  # any request the converter translated completely.
  defp fidelity_opts(untranslated) when map_size(untranslated) == 0,
    do: [client_format: :anthropic]

  defp fidelity_opts(untranslated) do
    [
      client_format: :anthropic,
      passthrough_request_fields: untranslated,
      passthrough_detail: "no equivalent in the OpenAI Chat Completions format"
    ]
  end

  # The Anthropic->OpenAI conversion is a whitelist, so any field we haven't
  # taught it about is invisible to every OpenAI-shaped provider — the client
  # sees a 200 and a response that quietly ignored what it asked for (this is
  # how structured outputs via `output_config` went unnoticed). The warning
  # stays even though Anthropic steps now receive the field: a translation we
  # haven't written is still a gap the moment the request falls back.
  defp warn_untranslated(params, request_id, router) do
    case AnthropicFormat.passthrough_fields(params) do
      untranslated when map_size(untranslated) == 0 ->
        %{}

      untranslated ->
        Logger.warning(
          "[AnthropicProxy] untranslated=#{untranslated |> Map.keys() |> Enum.sort() |> Enum.join(",")} " <>
            "request_id=#{request_id} router=#{router.slug} model=#{params["model"]}"
        )

        untranslated
    end
  end

  @doc """
  Anthropic-compatible `/v1/messages/count_tokens`. Claude Code calls this for
  compaction sizing. When the router has an Anthropic step with a usable key we
  forward for an exact count; otherwise we return a byte-based estimate —
  tokenizers differ per provider anyway, so an approximation is fine (see the
  reactive-handling philosophy in AGENTS.md).
  """
  def count_tokens(conn, params) do
    router = conn.assigns.current_router
    params = Map.drop(params, ["router_slug"])

    case forward_count_tokens(router, params, conn.req_headers) do
      {:ok, body} ->
        json(conn, body)

      :estimate ->
        json(conn, %{"input_tokens" => estimate_input_tokens(params)})
    end
  end

  defp forward_count_tokens(router, params, client_headers) do
    alias DodoRouter.Proxy.Adapters.Anthropic
    alias DodoRouter.{Providers, Routers}

    step =
      router
      |> Routers.list_routing_steps()
      |> Enum.find(&(&1.provider == "anthropic"))

    api_key =
      case step do
        %{provider_key: %{} = provider_key} -> Providers.resolve_api_key(provider_key)
        _ -> nil
      end

    with %{} <- step,
         key when is_binary(key) <- api_key,
         {:ok, body} <- Anthropic.count_tokens(params, step, key, client_headers) do
      {:ok, body}
    else
      _ -> :estimate
    end
  end

  # ~4 bytes/token is a reasonable ballpark for prompt text; base64 images
  # skew high, but overestimating is the safe direction for compaction checks.
  defp estimate_input_tokens(params) do
    params
    |> Map.take(["messages", "system", "tools"])
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
    |> max(1)
  end

  defp sync_anthropic(
         conn,
         router,
         openai_params,
         request_id,
         session,
         recording_id,
         client_headers,
         untranslated
       ) do
    start_time = System.monotonic_time(:millisecond)

    dispatch_opts =
      [
        request_id: request_id,
        session: session,
        client_headers: client_headers,
        recording_id: recording_id,
        dropped_query_params: dropped_query_params(conn)
      ] ++ fidelity_opts(untranslated)

    case Proxy.dispatch(router, openai_params, dispatch_opts) do
      {:ok, openai_response, timing} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        provider_ms = timing[:provider_ms] || 0

        anthropic_response =
          AnthropicFormat.from_openai_response(
            openai_response,
            timing[:response_passthrough] || %{}
          )

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
        |> forward_ratelimit_headers(timing[:response_headers])
        |> json(anthropic_response)

      {:error, :no_routing_configured} ->
        conn
        |> put_status(400)
        |> json(%{
          "type" => "error",
          "error" => %{
            "type" => "invalid_request_error",
            "message" =>
              "No routing configured for router '#{router.slug}'. Add a provider in the Dodo Router dashboard."
          }
        })

      {:error, :all_providers_failed, attempts} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        last_attempt = List.last(attempts)

        {status, error_response} =
          if last_attempt && last_attempt[:error] == "context_overflow" do
            {400,
             %{
               "type" => "error",
               "error" => %{
                 "type" => "invalid_request_error",
                 "message" => "Input exceeds context window of this model"
               }
             }}
          else
            {502,
             %{
               type: "error",
               error: %{
                 type: "provider_error",
                 message: "All providers failed: #{last_attempt[:error]}"
               }
             }}
          end

        conn
        |> put_status(status)
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> json(error_response)
    end
  end

  defp stream_anthropic(
         conn,
         router,
         openai_params,
         request_id,
         session,
         client_headers,
         recording_id,
         untranslated
       ) do
    # The 200 is deferred until the first byte of content actually arrives.
    # Sending it up front (as this did) meant a request that failed before any
    # provider produced output — context overflow, every key rate-limited —
    # reached the client as `200 OK` with an SSE error buried inside it, which
    # SDKs report as a successful empty response. The OpenAI-shaped endpoint
    # already defers for exactly this reason; this brings the Anthropic one in
    # line. `Process` rather than a rebound variable because `send_chunk` is a
    # closure and cannot rebind `conn`.
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-request-id", request_id)

    Process.put(:__stream_conn__, conn)
    Process.put(:anthropic_sse_state, AnthropicFormat.new_sse_state())
    Process.put(:__anthropic_serving_model__, openai_params["model"] || "unknown")
    # Keep-alive means the next request may land in this same process.
    Process.delete(:__stream_opened__)
    Process.delete(:__anthropic_passthrough_active__)
    Adapter.reset_stream_response_headers()

    send_chunk = &raw_send_chunk/1

    anthropic_send_chunk = fn data -> handle_stream_data(data, request_id) end

    result =
      Proxy.dispatch_streaming(
        router,
        openai_params,
        anthropic_send_chunk,
        [
          # The same id already went back as x-request-id; without it here the
          # log row gets a fresh one and the header names nothing.
          request_id: request_id,
          session: session,
          recording_id: recording_id,
          client_headers: client_headers,
          dropped_query_params: dropped_query_params(conn),
          # `message_start` carries the model and can never be revised, so the
          # client must be told which provider is answering *before* the first
          # chunk. Without this a silent fallback echoes back the requested
          # model and an agent session can run entirely on another provider
          # with nothing in the response to say so.
          on_step_start: fn %{model: model} ->
            Process.put(:__anthropic_serving_model__, model)
            :ok
          end
        ] ++ fidelity_opts(untranslated)
      )

    sse_state = Process.get(:anthropic_sse_state) || AnthropicFormat.new_sse_state()
    Process.delete(:anthropic_sse_state)
    Process.delete(:__anthropic_serving_model__)

    conn = finish_stream(result, sse_state, request_id, send_chunk)
    Process.delete(:__stream_conn__)
    Process.delete(:__stream_opened__)
    Process.delete(:__anthropic_passthrough_active__)
    conn
  end

  # Routes one chunk of adapter output onto the client's wire. Public (doc
  # false) so the passthrough/reframe split is testable without a live
  # Anthropic upstream.
  @doc false
  def handle_stream_data("event: " <> _ = native_sse_data, _request_id) do
    # Native events relayed verbatim by a passthrough step — the provider's
    # own message lifecycle is already on the wire, so no synthetic
    # message_start/content_block_start and no reframing.
    Process.put(:__anthropic_passthrough_active__, true)
    ensure_stream_head()
    raw_send_chunk(native_sse_data)
    :ok
  end

  def handle_stream_data(openai_sse_data, request_id) do
    state = Process.get(:anthropic_sse_state) || AnthropicFormat.new_sse_state()
    {anthropic_events, state} = AnthropicFormat.convert_sse_chunk(openai_sse_data, state)
    Process.put(:anthropic_sse_state, state)

    if anthropic_events != [] do
      open_stream(request_id)
      Enum.each(anthropic_events, &raw_send_chunk/1)
    end

    :ok
  end

  # Anthropic's stream lifecycle requires message_start and content_block_start
  # before any delta, so both are emitted lazily at the moment the first delta
  # is ready — which is also the moment the HTTP status stops being revisable.
  # A passthrough stream calls `ensure_stream_head/0` instead: the provider's
  # real message_start is about to be relayed, and a synthetic one on top of
  # it would open a second message.
  defp open_stream(request_id) do
    if Process.get(:__stream_opened__) != true do
      ensure_stream_head()

      model = Process.get(:__anthropic_serving_model__) || "unknown"
      # Anthropic's own id when Anthropic is serving: it names a message in
      # their store, which is what `previous_message_id` cache diagnostics
      # refer to. Any other provider has none, so we synthesise one.
      message_id = AnthropicAdapter.stream_message_id() || "msg_#{request_id}"
      raw_send_chunk(anthropic_message_start_event(model, message_id))
      raw_send_chunk(anthropic_content_block_start_event())
    end

    :ok
  end

  # The housekeeping half of opening the stream: commit the response head with
  # the provider's parked rate-limit headers, exactly once.
  defp ensure_stream_head do
    if Process.get(:__stream_opened__) != true do
      Process.put(:__stream_opened__, true)

      # Last moment the response head is still revisable. The adapter parked
      # the provider's headers when the upstream head arrived; this is where
      # the rate-limit ones get onto our own response, matching what the sync
      # path does from the dispatch meta.
      Process.put(
        :__stream_conn__,
        forward_ratelimit_headers(
          Process.get(:__stream_conn__),
          Adapter.stream_response_headers()
        )
      )
    end

    :ok
  end

  defp stream_open?, do: Process.get(:__stream_opened__) == true

  defp raw_send_chunk(data) do
    conn = Process.get(:__stream_conn__)
    conn = if conn.state == :unset, do: send_chunked(conn, 200), else: conn

    case chunk(conn, data) do
      {:ok, chunked} -> Process.put(:__stream_conn__, chunked)
      _error -> Process.put(:__stream_conn__, conn)
    end

    :ok
  end

  def finish_stream({:ok, openai_response, timing}, sse_state, request_id, send_chunk) do
    if Process.get(:__anthropic_passthrough_active__) == true do
      # The provider's own content_block_stop / message_delta / message_stop
      # were already relayed verbatim; a synthetic tail here would append a
      # second terminator to a finished message.
      Process.get(:__stream_conn__)
    else
      finish_reframed_stream(openai_response, timing, sse_state, request_id, send_chunk)
    end
  end

  def finish_stream({:error, :no_routing_configured}, _sse_state, _request_id, send_chunk) do
    stream_or_status(
      400,
      %{
        "type" => "error",
        "error" => %{"type" => "configuration_error", "message" => "No routing configured"}
      },
      send_chunk
    )
  end

  def finish_stream(
        {:error, :all_providers_failed, attempts},
        _sse_state,
        _request_id,
        send_chunk
      ) do
    last_attempt = List.last(attempts)

    {status, payload} =
      if last_attempt && last_attempt[:error] == "context_overflow" do
        {400,
         %{
           "type" => "error",
           "error" => %{
             "type" => "invalid_request_error",
             "message" => "Input exceeds context window of this model"
           }
         }}
      else
        {502,
         %{
           "type" => "error",
           "error" => %{"type" => "provider_error", "message" => "All providers failed"}
         }}
      end

    stream_or_status(status, payload, send_chunk)
  end

  # Nothing has been sent yet -> a real HTTP status the client's SDK can act
  # on. Content is already on the wire -> the status is spent, so the error can
  # only be an SSE event.
  defp finish_reframed_stream(openai_response, timing, sse_state, request_id, send_chunk) do
    choice = get_in(openai_response, ["choices", Access.at(0)]) || %{}
    stop_reason = convert_stop_reason(choice["finish_reason"])
    usage = openai_response["usage"] || %{}

    # A successful request that produced no content still owes the client a
    # well-formed, empty message rather than a bare 200 with no body.
    open_stream(request_id)

    :ok = send_chunk.(anthropic_content_block_stop_event(sse_state.open_block))

    :ok =
      send_chunk.(
        anthropic_message_delta_event(stop_reason, usage, timing[:response_passthrough] || %{})
      )

    :ok = send_chunk.(anthropic_message_stop_event())
    Process.get(:__stream_conn__)
  end

  defp stream_or_status(status, payload, send_chunk) do
    conn = Process.get(:__stream_conn__)

    if stream_open?() do
      :ok = send_chunk.("event: error\ndata: " <> Jason.encode!(payload) <> "\n\n")
      :ok = send_chunk.(anthropic_message_stop_event())
      Process.get(:__stream_conn__)
    else
      conn
      |> delete_resp_header("content-type")
      |> put_status(status)
      |> json(payload)
    end
  end

  defp anthropic_message_start_event(model, message_id) do
    event_data = %{
      "type" => "message_start",
      "message" => %{
        "id" => message_id,
        "type" => "message",
        "role" => "assistant",
        "content" => [],
        "model" => model,
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => %{
          "input_tokens" => 0,
          "output_tokens" => 0
        }
      }
    }

    "event: message_start\ndata: #{Jason.encode!(event_data)}\n\n"
  end

  defp anthropic_content_block_start_event do
    event_data = %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{
        "type" => "text",
        "text" => ""
      }
    }

    "event: content_block_start\ndata: #{Jason.encode!(event_data)}\n\n"
  end

  defp anthropic_content_block_stop_event(index) do
    event_data = %{
      "type" => "content_block_stop",
      "index" => index
    }

    "event: content_block_stop\ndata: #{Jason.encode!(event_data)}\n\n"
  end

  # `passthrough` is what Anthropic put on its own tail event that the OpenAI
  # chunk shape could not carry — `context_management` applied edits,
  # `stop_details` behind a refusal, and the `stop_sequence` that actually
  # matched. It is empty unless Anthropic itself served the request.
  #
  # `stop_sequence` is the reason the split is delta-vs-top rather than one
  # blob: hardcoding it nil here is a lie whenever the client supplied stop
  # sequences and one of them ended the turn.
  defp anthropic_message_delta_event(stop_reason, usage, passthrough) do
    {delta_extras, top_extras} = Map.split(passthrough, ["stop_sequence"])

    event_data =
      %{
        "type" => "message_delta",
        "delta" =>
          Map.merge(
            %{"stop_reason" => stop_reason, "stop_sequence" => nil},
            delta_extras
          ),
        "usage" => %{
          "output_tokens" => usage["completion_tokens"] || 0
        }
      }
      |> Map.merge(top_extras)

    "event: message_delta\ndata: #{Jason.encode!(event_data)}\n\n"
  end

  defp anthropic_message_stop_event do
    "event: message_stop\ndata: #{Jason.encode!(%{"type" => "message_stop"})}\n\n"
  end

  defp convert_stop_reason("stop"), do: "end_turn"
  defp convert_stop_reason("tool_calls"), do: "tool_use"
  defp convert_stop_reason("length"), do: "max_tokens"
  defp convert_stop_reason(other), do: other

  defp extract_session(conn) do
    router = conn.assigns.current_router
    session_header = router.session_header || "x-session-id"
    session_name_header = derive_session_name_header(session_header)

    %{
      session_id: get_req_header(conn, session_header) |> List.first(),
      session_name: get_req_header(conn, session_name_header) |> List.first()
    }
  end

  defp derive_session_name_header("x-session-id"), do: "x-session-name"
  defp derive_session_name_header(header), do: header <> "-name"

  defp extract_active_recording_id(router) do
    alias DodoRouter.Recordings

    case Recordings.get_active_recording(router) do
      nil -> nil
      recording -> recording.id
    end
  end
end
