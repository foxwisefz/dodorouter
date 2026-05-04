defmodule DodoRouterWeb.ProxyController do
  use DodoRouterWeb, :controller

  require Logger

  alias DodoRouter.Proxy

  def create(conn, params) do
    router = conn.assigns.current_router
    request_id = Ecto.UUID.generate()
    session = extract_session(conn)

    recording_id = extract_active_recording_id(router)
    client_headers = extract_forwardable_headers(conn)

    Logger.info(
      "[Proxy] request_id=#{request_id} router=#{router.slug} stream=#{params["stream"]} " <>
        "model=#{params["model"]} msg_count=#{length(params["messages"] || [])} " <>
        "client_headers=#{inspect(redact_headers(client_headers))}"
    )

    if params["stream"] == true do
      stream_response(conn, router, params, request_id, session, client_headers, recording_id)
    else
      sync_response(conn, router, params, request_id, session, recording_id, client_headers)
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

  defp extract_session(conn) do
    %{
      session_id: get_req_header(conn, "x-session-id") |> List.first(),
      session_name: get_req_header(conn, "x-session-name") |> List.first()
    }
  end

  defp extract_active_recording_id(router) do
    alias DodoRouter.Recordings

    case Recordings.get_active_recording(router) do
      nil -> nil
      recording -> recording.id
    end
  end

  @hop_by_hop_headers ~w(host connection content-length transfer-encoding upgrade proxy-authorization proxy-authenticate te trailer)
                      |> Enum.map(&String.downcase/1)

  defp extract_forwardable_headers(conn) do
    conn.req_headers
    |> Enum.reject(fn {key, _} -> String.downcase(key) in @hop_by_hop_headers end)
  end

  defp sync_response(conn, router, params, request_id, session, recording_id, client_headers) do
    start_time = System.monotonic_time(:millisecond)

    case Proxy.dispatch(router, params,
           request_id: request_id,
           session: session,
           client_headers: client_headers,
           recording_id: recording_id
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
        |> json(response)

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
        last_attempt = List.last(attempts)

        conn
        |> put_status(502)
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
        |> json(%{
          error: %{
            message: "All providers failed",
            type: "provider_error",
            last_error: last_attempt[:error],
            attempts: length(attempts)
          }
        })
    end
  end

  defp stream_response(conn, router, params, request_id, session, client_headers, recording_id) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-request-id", request_id)
      |> send_chunked(200)

    send_chunk = fn data ->
      chunk(conn, data)
      :ok
    end

    case Proxy.dispatch_streaming(router, params, send_chunk,
           session: session,
           recording_id: recording_id,
           client_headers: client_headers
         ) do
      {:ok, _response, _timing} ->
        conn

      {:error, :no_routing_configured} ->
        error_event =
          "data: " <> Jason.encode!(%{error: %{message: "No routing configured"}}) <> "\n\n"

        chunk(conn, error_event)
        chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, :all_providers_failed, _attempts} ->
        error_event =
          "data: " <> Jason.encode!(%{error: %{message: "All providers failed"}}) <> "\n\n"

        chunk(conn, error_event)
        chunk(conn, "data: [DONE]\n\n")
        conn
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
