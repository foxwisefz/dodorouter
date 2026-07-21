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
         recording_id
       ) do
    model = openai_params["model"] || "unknown"

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

    # Anthropic streaming lifecycle requires message_start and
    # content_block_start to precede any content_block_delta events.
    :ok = send_chunk.(anthropic_message_start_event(model, request_id))
    :ok = send_chunk.(anthropic_content_block_start_event())

    # Block lifecycle state for the SSE converter; kept in the process
    # dictionary because send_chunk closures can't rebind it.
    Process.put(:anthropic_sse_state, AnthropicFormat.new_sse_state())

    anthropic_send_chunk = fn openai_sse_data ->
      state = Process.get(:anthropic_sse_state) || AnthropicFormat.new_sse_state()
      {anthropic_events, state} = AnthropicFormat.convert_sse_chunk(openai_sse_data, state)
      Process.put(:anthropic_sse_state, state)
      Enum.each(anthropic_events, &send_chunk.(&1))
      :ok
    end

    result =
      Proxy.dispatch_streaming(router, openai_params, anthropic_send_chunk,
        session: session,
        recording_id: recording_id,
        client_headers: client_headers
      )

    sse_state = Process.get(:anthropic_sse_state) || AnthropicFormat.new_sse_state()
    Process.delete(:anthropic_sse_state)

    case result do
      {:ok, openai_response, _timing} ->
        choice = get_in(openai_response, ["choices", Access.at(0)]) || %{}
        stop_reason = convert_stop_reason(choice["finish_reason"])
        usage = openai_response["usage"] || %{}

        :ok = send_chunk.(anthropic_content_block_stop_event(sse_state.open_block))
        :ok = send_chunk.(anthropic_message_delta_event(stop_reason, usage))
        :ok = send_chunk.(anthropic_message_stop_event())
        conn

      {:error, :no_routing_configured} ->
        error_event =
          "event: error\ndata: " <>
            Jason.encode!(%{
              type: "error",
              error: %{type: "configuration_error", message: "No routing configured"}
            }) <> "\n\n"

        :ok = send_chunk.(error_event)
        :ok = send_chunk.(anthropic_message_stop_event())
        conn

      {:error, :all_providers_failed, attempts} ->
        last_attempt = List.last(attempts)

        error_payload =
          if last_attempt && last_attempt[:error] == "context_overflow" do
            %{
              type: "error",
              error: %{
                type: "invalid_request_error",
                message: "Input exceeds context window of this model"
              }
            }
          else
            %{
              type: "error",
              error: %{type: "provider_error", message: "All providers failed"}
            }
          end

        error_event =
          "event: error\ndata: " <> Jason.encode!(error_payload) <> "\n\n"

        :ok = send_chunk.(error_event)
        :ok = send_chunk.(anthropic_message_stop_event())
        conn
    end
  end

  defp anthropic_message_start_event(model, request_id) do
    event_data = %{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_#{request_id}",
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

  defp anthropic_message_delta_event(stop_reason, usage) do
    event_data = %{
      "type" => "message_delta",
      "delta" => %{
        "stop_reason" => stop_reason,
        "stop_sequence" => nil
      },
      "usage" => %{
        "output_tokens" => usage["completion_tokens"] || 0
      }
    }

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

  @hop_by_hop_headers ~w(host connection content-length transfer-encoding upgrade proxy-authorization proxy-authenticate te trailer)
                      |> Enum.map(&String.downcase/1)

  defp extract_forwardable_headers(conn) do
    conn.req_headers
    |> Enum.reject(fn {key, _} -> String.downcase(key) in @hop_by_hop_headers end)
  end
end
