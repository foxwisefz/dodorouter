defmodule DodoRouterWeb.AnthropicProxyController do
  use DodoRouterWeb, :controller

  require Logger

  alias DodoRouter.Proxy
  alias DodoRouterWeb.AnthropicFormat

  def create(conn, params) do
    router = conn.assigns.current_router
    request_id = Ecto.UUID.generate()
    session = extract_session(conn)
    recording_id = extract_active_recording_id(router)
    client_headers = extract_forwardable_headers(conn)

    openai_params = AnthropicFormat.to_openai_params(params)

    Logger.info(
      "[AnthropicProxy] request_id=#{request_id} router=#{router.slug} stream=#{params["stream"]} " <>
        "model=#{params["model"]} msg_count=#{length(params["messages"] || [])}"
    )

    if params["stream"] == true do
      stream_anthropic(
        conn,
        router,
        openai_params,
        request_id,
        session,
        client_headers,
        recording_id
      )
    else
      sync_anthropic(
        conn,
        router,
        openai_params,
        request_id,
        session,
        recording_id,
        client_headers
      )
    end
  end

  defp sync_anthropic(
         conn,
         router,
         openai_params,
         request_id,
         session,
         recording_id,
         client_headers
       ) do
    start_time = System.monotonic_time(:millisecond)

    case Proxy.dispatch(router, openai_params,
           request_id: request_id,
           session: session,
           client_headers: client_headers,
           recording_id: recording_id
         ) do
      {:ok, openai_response, timing} ->
        total_ms = System.monotonic_time(:millisecond) - start_time
        provider_ms = timing[:provider_ms] || 0
        anthropic_response = AnthropicFormat.from_openai_response(openai_response)

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
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

        conn
        |> put_status(502)
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> json(%{
          type: "error",
          error: %{
            type: "provider_error",
            message: "All providers failed: #{last_attempt[:error]}"
          }
        })
    end
  end

  defp stream_anthropic(
         conn,
         router,
         openai_params,
         request_id,
         session,
         client_headers,
         recording_id
       ) do
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

    anthropic_send_chunk = fn openai_sse_data ->
      case AnthropicFormat.convert_sse_chunk(openai_sse_data) do
        {:ok, anthropic_events} ->
          Enum.each(anthropic_events, &send_chunk.(&1))

        :skip ->
          :ok
      end

      :ok
    end

    case Proxy.dispatch_streaming(router, openai_params, anthropic_send_chunk,
           session: session,
           recording_id: recording_id,
           client_headers: client_headers
         ) do
      {:ok, openai_response, _timing} ->
        msg_start = anthropic_message_start_event(openai_response, request_id)
        :ok = send_chunk.(msg_start)
        conn

      {:error, :no_routing_configured} ->
        error_event =
          "event: error\ndata: " <>
            Jason.encode!(%{
              type: "error",
              error: %{type: "configuration_error", message: "No routing configured"}
            }) <> "\n\n"

        chunk(conn, error_event)
        conn

      {:error, :all_providers_failed, _attempts} ->
        error_event =
          "event: error\ndata: " <>
            Jason.encode!(%{
              type: "error",
              error: %{type: "provider_error", message: "All providers failed"}
            }) <> "\n\n"

        chunk(conn, error_event)
        conn
    end
  end

  defp anthropic_message_start_event(openai_response, request_id) do
    message = get_in(openai_response, ["choices", Access.at(0), "message"]) || %{}
    content = message["content"] || ""
    usage = openai_response["usage"] || %{}

    event_data = %{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_#{request_id}",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => content}],
        "model" => openai_response["model"] || "unknown",
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{
          "input_tokens" => usage["prompt_tokens"] || 0,
          "output_tokens" => usage["completion_tokens"] || 0
        }
      }
    }

    "event: message_start\ndata: #{Jason.encode!(event_data)}\n\n"
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
end
