defmodule DodoRouterWeb.ProxyController do
  use DodoRouterWeb, :controller

  alias DodoRouter.Proxy

  def create(conn, params) do
    router = conn.assigns.current_router
    request_id = Ecto.UUID.generate()

    if params["stream"] == true do
      stream_response(conn, router, params, request_id)
    else
      sync_response(conn, router, params, request_id)
    end
  end

  # Legacy endpoint for backwards compatibility
  def create_legacy(conn, params) do
    create(conn, params)
  end

  defp sync_response(conn, router, params, request_id) do
    start_time = System.monotonic_time(:millisecond)

    case Proxy.dispatch(router, params, request_id: request_id) do
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
        |> put_status(500)
        |> json(%{
          error: %{message: "No routing configured for this router", type: "configuration_error"}
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

  defp stream_response(conn, router, params, request_id) do
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

    case Proxy.dispatch_streaming(router, params, send_chunk) do
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
end
