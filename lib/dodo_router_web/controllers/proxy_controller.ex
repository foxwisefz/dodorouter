defmodule DodoRouterWeb.ProxyController do
  use DodoRouterWeb, :controller

  require Logger

  alias DodoRouter.Proxy

  def create(conn, params) do
    router = conn.assigns.current_router
    request_id = Ecto.UUID.generate()
    session = extract_session(conn)

    recording_id = extract_active_recording_id(router)
    client_headers = conn.req_headers

    Logger.info(
      "[Proxy] request_id=#{request_id} router=#{router.slug} stream=#{params["stream"]} " <>
        "model=#{params["model"]} msg_count=#{length(params["messages"] || [])} " <>
        "client_headers=#{inspect(redact_headers(client_headers))}"
    )

    idempotency_key = get_req_header(conn, "idempotency-key") |> List.first()

    cond do
      params["stream"] == true and is_binary(idempotency_key) ->
        # A guarantee the proxy cannot honor must be refused, not silently
        # dropped: stored responses replay as JSON, and a streaming client
        # would hang waiting for SSE that never comes.
        conn
        |> put_status(400)
        |> json(%{
          error: %{
            message:
              "Idempotency-Key is not supported on streaming requests. Retry without stream, or without the header.",
            type: "invalid_request_error"
          }
        })

      params["stream"] == true ->
        stream_response(conn, router, params, request_id, session, client_headers, recording_id)

      true ->
        sync_response(
          conn,
          router,
          params,
          request_id,
          session,
          recording_id,
          client_headers,
          idempotency_key
        )
    end
  end

  def models(conn, _params) do
    router = conn.assigns.current_router

    model = %{
      id: router.slug,
      object: "model",
      created: router.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(),
      owned_by: "dodo"
    }

    json(conn, %{object: "list", data: [model]})
  end

  # Legacy endpoint for backwards compatibility
  def create_legacy(conn, params) do
    create(conn, params)
  end

  # Stripe precedent: replays are marked on the wire, so a client can tell
  # a fresh answer from a re-served one without diffing bodies.
  defp maybe_replayed_header(conn, %{idempotent_replay: true}),
    do: put_resp_header(conn, "idempotent-replayed", "true")

  defp maybe_replayed_header(conn, _timing), do: conn

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

  defp sync_response(
         conn,
         router,
         params,
         request_id,
         session,
         recording_id,
         client_headers,
         idempotency_key
       ) do
    start_time = System.monotonic_time(:millisecond)

    case Proxy.dispatch(router, params,
           request_id: request_id,
           session: session,
           client_headers: client_headers,
           recording_id: recording_id,
           idempotency_key: idempotency_key
         ) do
      {:ok, response, timing} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        provider_ms = timing[:provider_ms] || 0
        overhead_ms = total_ms - provider_ms

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
        |> put_resp_header("x-timing-overhead-ms", to_string(overhead_ms))
        |> maybe_replayed_header(timing)
        |> json(response)

      {:error, :idempotency_in_progress} ->
        conn
        |> put_status(409)
        |> put_resp_header("x-request-id", request_id)
        |> json(%{
          error: %{
            message:
              "A request with this Idempotency-Key is still executing. Retry after it completes.",
            type: "idempotency_error",
            code: "idempotency_in_progress"
          }
        })

      {:error, :idempotency_key_mismatch} ->
        conn
        |> put_status(409)
        |> put_resp_header("x-request-id", request_id)
        |> json(%{
          error: %{
            message:
              "This Idempotency-Key was already used with a different request body. Keys must be unique per request.",
            type: "idempotency_error",
            code: "idempotency_key_reused"
          }
        })

      {:error, :no_routing_configured} ->
        conn
        |> put_status(400)
        |> json(%{
          error: %{
            message:
              "No routing configured for router '#{router.slug}'. Add a provider in the Dodo Router dashboard.",
            type: "invalid_request_error"
          }
        })

      {:error, :all_providers_failed, attempts} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        provider_ms = attempts |> Enum.map(& &1[:latency_ms]) |> Enum.sum()
        {status, error_response} = Proxy.error_response(attempts)

        conn
        |> put_status(status)
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
        |> json(error_response)
    end
  end

  defp stream_response(conn, router, params, request_id, session, client_headers, recording_id) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-request-id", request_id)

    # Use process dictionary to track the mutable conn state across chunk callbacks.
    # This lets us delay sending HTTP 200 until we know the request will succeed.
    # If all providers fail before any chunks are sent, we can return HTTP 400
    # instead of HTTP 200 + SSE error — which is critical for client SDKs like
    # the AI SDK to properly detect errors (e.g. context overflow) via APICallError.
    #
    # We use Process.put/Process.get (not Agent) because Bandit requires that
    # send_chunked/2 and chunk/2 be called by the stream owner process. All
    # adapter callbacks run in the controller process, so the process dictionary
    # stays in the same process.
    Process.put(:__stream_conn__, conn)

    send_chunk = fn data ->
      current_conn = Process.get(:__stream_conn__)

      # send_chunked/2 can only be called once per connection.
      # After the first chunk it transitions state to :chunked.
      new_conn =
        if current_conn.state == :unset do
          send_chunked(current_conn, 200)
        else
          current_conn
        end

      case chunk(new_conn, data) do
        {:ok, chunked_conn} ->
          Process.put(:__stream_conn__, chunked_conn)
          :ok

        _error ->
          Process.put(:__stream_conn__, new_conn)
          :ok
      end
    end

    result =
      Proxy.dispatch_streaming(router, params, send_chunk,
        # The same id already went back as x-request-id; without it here the
        # log row gets a fresh one and the header names nothing.
        request_id: request_id,
        session: session,
        recording_id: recording_id,
        client_headers: client_headers
      )

    final_conn = Process.get(:__stream_conn__)
    Process.delete(:__stream_conn__)

    case result do
      {:ok, _response, _timing} ->
        if final_conn.state == :unset do
          # No chunks sent — close the stream cleanly
          {:ok, done_conn} = send_chunked(final_conn, 200) |> chunk("data: [DONE]\n\n")
          done_conn
        else
          final_conn
        end

      {:error, :no_routing_configured} ->
        if final_conn.state == :unset do
          final_conn
          |> put_status(400)
          |> put_resp_content_type("application/json")
          |> json(%{error: %{message: "No routing configured"}})
        else
          {:ok, done_conn} = chunk(final_conn, "data: [DONE]\n\n")
          done_conn
        end

      {:error, :all_providers_failed, attempts} ->
        if final_conn.state == :unset do
          # No chunks were sent to the client yet.
          # Return a proper HTTP error status so client SDKs (e.g. AI SDK) detect
          # this as an APICallError rather than a generic stream error.
          {status, error_response} = Proxy.error_response(attempts)

          final_conn
          |> put_status(status)
          |> put_resp_content_type("application/json")
          |> json(error_response)
        else
          # Chunks were already streamed to the client.
          # Must continue with SSE format since we can't change HTTP status mid-stream.
          error_payload = Proxy.streaming_error_payload(attempts)
          error_event = "data: " <> Jason.encode!(error_payload) <> "\n\n"

          final_conn
          |> chunk(error_event)
          |> case do
            {:ok, err_conn} ->
              {:ok, done_conn} = chunk(err_conn, "data: [DONE]\n\n")
              done_conn

            _ ->
              final_conn
          end
        end
    end
  end

  defp redact_headers(headers) do
    Enum.map(headers, fn
      {"authorization", _} -> {"authorization", "***"}
      {k, _v} when k in ["cookie", "set-cookie"] -> {k, "***"}
      other -> other
    end)
  end
end
