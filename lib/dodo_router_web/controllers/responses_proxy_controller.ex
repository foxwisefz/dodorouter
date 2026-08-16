defmodule DodoRouterWeb.ResponsesProxyController do
  use DodoRouterWeb, :controller

  require Logger

  alias DodoRouter.Proxy
  alias DodoRouterWeb.ResponsesFormat

  def create(conn, params) do
    router = conn.assigns.current_router
    request_id = Ecto.UUID.generate()
    session = extract_session(conn)
    recording_id = extract_active_recording_id(router)
    client_headers = conn.req_headers

    openai_params = ResponsesFormat.to_openai_params(params)

    Logger.info(
      "[ResponsesProxy] request_id=#{request_id} router=#{router.slug} stream=#{params["stream"]} " <>
        "model=#{params["model"]}"
    )

    dropped_fields = warn_dropped_fields(params, request_id, router)
    idempotency_key = get_req_header(conn, "idempotency-key") |> List.first()

    cond do
      params["stream"] == true and is_binary(idempotency_key) ->
        # A guarantee the proxy cannot honor must be refused, not silently
        # dropped: stored responses replay as JSON, and a streaming client
        # would hang waiting for SSE that never comes.
        conn
        |> put_status(400)
        |> json(%{
          "error" => %{
            "message" =>
              "Idempotency-Key is not supported on streaming requests. Retry without stream, or without the header.",
            "type" => "invalid_request_error"
          }
        })

      params["stream"] == true ->
        stream_responses(
          conn,
          router,
          openai_params,
          request_id,
          session,
          client_headers,
          recording_id,
          dropped_fields
        )

      true ->
        sync_responses(
          conn,
          router,
          openai_params,
          request_id,
          session,
          recording_id,
          client_headers,
          dropped_fields,
          idempotency_key
        )
    end
  end

  # Stripe precedent: replays are marked on the wire, so a client can tell
  # a fresh answer from a re-served one without diffing bodies.
  defp maybe_replayed_header(conn, %{idempotent_replay: true}),
    do: put_resp_header(conn, "idempotent-replayed", "true")

  defp maybe_replayed_header(conn, _timing), do: conn

  # See AnthropicProxyController: ingress conversion drops travel to the
  # request log alongside the header and egress-allowlist drops.
  # Always declared, not only when dropped fields exist — the response
  # passthrough (real `resp_…` ids and untranslated response fields) keys off
  # `client_format` on every request. See AnthropicProxyController.
  defp fidelity_opts(fields) when map_size(fields) == 0, do: [client_format: :responses]

  defp fidelity_opts(fields) do
    [
      client_format: :responses,
      passthrough_request_fields: fields,
      passthrough_detail: "no equivalent in the OpenAI Chat Completions format"
    ]
  end

  defp sync_responses(
         conn,
         router,
         openai_params,
         request_id,
         session,
         recording_id,
         client_headers,
         dropped_fields,
         idempotency_key
       ) do
    start_time = System.monotonic_time(:millisecond)

    dispatch_opts =
      [
        request_id: request_id,
        session: session,
        client_headers: client_headers,
        recording_id: recording_id,
        idempotency_key: idempotency_key
      ] ++ fidelity_opts(dropped_fields)

    case Proxy.dispatch(router, openai_params, dispatch_opts) do
      {:ok, openai_response, timing} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        provider_ms = timing[:provider_ms] || 0

        responses_response =
          ResponsesFormat.from_openai_response(
            openai_response,
            request_id,
            timing[:response_passthrough] || %{}
          )

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
        |> maybe_replayed_header(timing)
        |> json(responses_response)

      {:error, :idempotency_in_progress} ->
        conn
        |> put_status(409)
        |> put_resp_header("x-request-id", request_id)
        |> json(%{
          "error" => %{
            "message" =>
              "A request with this Idempotency-Key is still executing. Retry after it completes.",
            "type" => "idempotency_error",
            "code" => "idempotency_in_progress"
          }
        })

      {:error, :idempotency_key_mismatch} ->
        conn
        |> put_status(409)
        |> put_resp_header("x-request-id", request_id)
        |> json(%{
          "error" => %{
            "message" =>
              "This Idempotency-Key was already used with a different request body. Keys must be unique per request.",
            "type" => "idempotency_error",
            "code" => "idempotency_key_reused"
          }
        })

      {:error, :no_routing_configured} ->
        conn
        |> put_status(400)
        |> json(%{
          "error" => %{
            "message" =>
              "No routing configured for router '#{router.slug}'. Add a provider in the Dodo Router dashboard.",
            "type" => "invalid_request_error"
          }
        })

      {:error, :all_providers_failed, attempts} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        last_attempt = List.last(attempts)

        {status, error_response} =
          if last_attempt && last_attempt[:error] == "context_overflow" do
            {400,
             %{
               "error" => %{
                 "message" => "Input exceeds context window of this model",
                 "type" => "invalid_request_error",
                 "code" => "context_length_exceeded"
               }
             }}
          else
            {502,
             %{
               "error" => %{
                 "message" => "All providers failed: #{last_attempt[:error]}",
                 "type" => "provider_error"
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

  defp stream_responses(
         conn,
         router,
         openai_params,
         request_id,
         session,
         client_headers,
         recording_id,
         dropped_fields
       ) do
    # Check routing BEFORE starting chunked response so we can return proper HTTP status
    conn =
      if DodoRouter.Routers.list_routing_steps(router) == [] do
        Logger.warning("[ResponsesProxy] request_id=#{request_id} no routing configured")

        conn
        |> put_status(400)
        |> json(%{
          "error" => %{
            "message" =>
              "No routing configured for router '#{router.slug}'. Add a provider in the Dodo Router dashboard.",
            "type" => "invalid_request_error"
          }
        })
      else
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-request-id", request_id)
        |> send_chunked(200)
      end

    # If conn is already sent (JSON error response), return it
    if conn.state == :sent do
      conn
    else
      send_chunk = fn data ->
        chunk(conn, data)
        :ok
      end

      model = openai_params["model"] || "unknown"
      created_at = System.system_time(:second)

      # Build a proper initial response object for response.created
      initial_response = %{
        "id" => "resp_#{request_id}",
        "object" => "response",
        "created_at" => created_at,
        "status" => "in_progress",
        "error" => nil,
        "incomplete_details" => nil,
        "instructions" => nil,
        "max_output_tokens" => nil,
        "model" => model,
        "output" => [],
        "parallel_tool_calls" => true,
        "previous_response_id" => nil,
        "reasoning" => %{"effort" => nil, "summary" => nil},
        "temperature" => nil,
        "text" => %{"format" => %{"type" => "text"}},
        "tool_choice" => "auto",
        "tools" => [],
        "top_p" => nil,
        "truncation" => "disabled",
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
        "user" => nil,
        "metadata" => %{}
      }

      created_event = %{
        "type" => "response.created",
        "response" => initial_response
      }

      send_chunk.("event: response.created\ndata: #{Jason.encode!(created_event)}\n\n")

      responses_send_chunk = fn openai_sse_data ->
        case ResponsesFormat.convert_sse_chunk(openai_sse_data, request_id) do
          {:ok, events} ->
            Enum.each(events, &send_chunk.(&1))

          :skip ->
            :ok
        end

        :ok
      end

      dispatch_opts =
        [
          # The same id already went back as x-request-id; without it here the
          # log row gets a fresh one and the header names nothing.
          request_id: request_id,
          session: session,
          recording_id: recording_id,
          client_headers: client_headers
        ] ++ fidelity_opts(dropped_fields)

      case Proxy.dispatch_streaming(router, openai_params, responses_send_chunk, dispatch_opts) do
        {:ok, openai_response, timing} ->
          Logger.info("[ResponsesProxy] request_id=#{request_id} streaming succeeded")

          # Convert the OpenAI response to Responses API format for response.completed
          completed_response =
            ResponsesFormat.from_openai_response(
              openai_response,
              request_id,
              timing[:response_passthrough] || %{}
            )

          completed_response =
            completed_response
            |> Map.put("status", "completed")
            |> Map.put("created_at", created_at)

          completed_event = %{
            "type" => "response.completed",
            "response" => completed_response
          }

          send_chunk.("event: response.completed\ndata: #{Jason.encode!(completed_event)}\n\n")
          conn

        {:error, :all_providers_failed, attempts} ->
          last_attempt = List.last(attempts)
          last_error = if last_attempt, do: last_attempt[:error], else: "unknown"

          Logger.error(
            "[ResponsesProxy] request_id=#{request_id} all providers failed: #{last_error}"
          )

          # Send error as SSE event since we've already started chunked mode
          error_payload =
            if last_attempt && last_attempt[:error] == "context_overflow" do
              %{
                "error" => %{
                  "message" => "Input exceeds context window of this model",
                  "type" => "invalid_request_error",
                  "code" => "context_length_exceeded"
                }
              }
            else
              %{
                "error" => %{
                  "message" => "All providers failed: #{last_error}",
                  "type" => "provider_error"
                }
              }
            end

          error_event =
            "event: error\ndata: " <> Jason.encode!(error_payload) <> "\n\n"

          send_chunk.(error_event)
          conn
      end
    end
  end

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

  # See AnthropicProxyController: the conversion is a whitelist, so anything it
  # doesn't carry is dropped in silence. Logging it turns that into a work
  # queue rather than a bug report from a confused client.
  # The warning stays even though Responses-format steps now receive these
  # fields: a translation we haven't written is still a gap the moment the
  # request falls back to any other provider.
  defp warn_dropped_fields(params, request_id, router) do
    case ResponsesFormat.passthrough_fields(params) do
      untranslated when map_size(untranslated) == 0 ->
        %{}

      untranslated ->
        Logger.warning(
          "[ResponsesProxy] dropped_fields=#{untranslated |> Map.keys() |> Enum.join(",")} " <>
            "request_id=#{request_id} router=#{router.slug} model=#{params["model"]}"
        )

        # The values travel with the names: we never store the client's body,
        # so the log row is the only surviving record of what was asked for.
        untranslated
    end
  end
end
