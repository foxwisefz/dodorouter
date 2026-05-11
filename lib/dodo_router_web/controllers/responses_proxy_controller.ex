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
    client_headers = extract_forwardable_headers(conn)

    openai_params = ResponsesFormat.to_openai_params(params)

    Logger.info(
      "[ResponsesProxy] request_id=#{request_id} router=#{router.slug} stream=#{params["stream"]} " <>
        "model=#{params["model"]}"
    )

    if params["stream"] == true do
      stream_responses(
        conn,
        router,
        openai_params,
        request_id,
        session,
        client_headers,
        recording_id
      )
    else
      sync_responses(
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

  defp sync_responses(
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
        responses_response = ResponsesFormat.from_openai_response(openai_response, request_id)

        conn
        |> put_resp_header("x-request-id", request_id)
        |> put_resp_header("x-timing-total-ms", to_string(total_ms))
        |> put_resp_header("x-timing-provider-ms", to_string(provider_ms))
        |> json(responses_response)

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
         recording_id
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

      case Proxy.dispatch_streaming(router, openai_params, responses_send_chunk,
             session: session,
             recording_id: recording_id,
             client_headers: client_headers
           ) do
        {:ok, openai_response, _timing} ->
          Logger.info("[ResponsesProxy] request_id=#{request_id} streaming succeeded")

          # Convert the OpenAI response to Responses API format for response.completed
          completed_response = ResponsesFormat.from_openai_response(openai_response, request_id)

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
