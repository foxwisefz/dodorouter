defmodule DodoRouter.Proxy.Adapters.TestProvider do
  @moduledoc """
  Test adapter for integration tests.

  Simulates an OpenAI-compatible provider for end-to-end testing.
  Calls send_chunk from a spawned process to mirror real adapter behavior
  (which invokes send_chunk from Finch's response callback process).

  It runs the same header and request-body policy as a real adapter and throws
  the result away. That is deliberate: it makes this a faithful stand-in for
  end-to-end tests of what the proxy strips and records, instead of a provider
  that is silently exempt from the rules everything else follows.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "test_provider",
    display_name: "Test Provider",
    # The extra coding slug lets tests exercise plan-based keys
    # (key slug != provider) end to end without a real provider.
    key_slugs: ["test_provider", "test_provider_coding"],
    endpoints: %{
      "test_provider" => "http://localhost:9999",
      "test_provider_coding" => "http://localhost:9999"
    },
    models: ~w(test-model),
    color: "gray",
    short_description: "Test provider for integration tests"

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Routers.RoutingStep

  # Real providers return rate-limit headers alongside the response; the
  # simulator does too, so the egress paths that forward them are testable.
  @ratelimit_headers [
    {"anthropic-ratelimit-unified-remaining", "42"},
    {"anthropic-ratelimit-unified-reset", "2026-08-11T12:00:00Z"}
  ]

  @doc false
  def request_headers(api_key, client_headers) do
    Adapter.build_forwarded_headers(client_headers, [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ])
  end

  # Lets a test build a chain whose first step fails *after* the upstream
  # request was constructed — the only way to exercise the error path of
  # anything recorded while building it.
  @failing_model "fail-model"

  @impl Adapter
  def call(request, %RoutingStep{} = step, api_key, client_headers) do
    maybe_crash(request)
    _ = simulate_upstream_request(request, api_key, client_headers)

    if step.model == @failing_model do
      simulated_failure()
    else
      ok_response(step)
    end
  end

  defp simulated_failure do
    {:error, :server_error, %{status: 500, body: "simulated failure", latency_ms: 1}}
  end

  defp ok_response(step) do
    response = %{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => "Hello from #{step.model}"
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15
      },
      "_meta" => %{
        "ttfb_ms" => 100,
        "upload_ms" => 10,
        "payload_size_bytes" => 100,
        "provider_processing_ms" => 50
      }
    }

    {:ok, response, %{headers: [{"content-type", "application/json"} | @ratelimit_headers]}}
  end

  @impl Adapter
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers) do
    maybe_crash(request)
    _ = simulate_upstream_request(request, api_key, client_headers)

    if step.model == @failing_model do
      simulated_failure()
    else
      do_stream(step, send_chunk)
    end
  end

  defp do_stream(%RoutingStep{} = step, send_chunk) do
    content = "Hello from #{step.model}"

    # As a real streaming adapter does: park the head's headers before the
    # first chunk, while the egress can still add to its own response.
    Adapter.record_stream_response_headers([
      {"content-type", "text/event-stream"} | @ratelimit_headers
    ])

    # Send chunks inline (same process), mirroring how real adapters call
    # send_chunk from Req.post's into callback, which runs in the caller process.
    words = String.split(content, " ")

    for word <- words do
      chunk = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"content" => word <> " "},
            "finish_reason" => nil
          }
        ]
      }

      sse_event = "data: " <> Jason.encode!(chunk) <> "\n\n"
      send_chunk.(sse_event)
    end

    # Send finish chunk
    finish_chunk = %{
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15
      }
    }

    send_chunk.("data: " <> Jason.encode!(finish_chunk) <> "\n\n")
    send_chunk.("data: [DONE]\n\n")

    response = %{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15
      },
      "_meta" => %{
        "ttfb_ms" => 100,
        "upload_ms" => 10,
        "payload_size_bytes" => 100,
        "provider_processing_ms" => 50
      }
    }

    {:ok, response, %{headers: [{"content-type", "text/event-stream"} | @ratelimit_headers]}}
  end

  # Lets tests exercise an adapter that raises mid-chain (e.g. a malformed
  # request crashing request conversion, as in the pre-0.1.x system-content-blocks bug).
  defp maybe_crash(%{"__crash__" => true}), do: raise(ArgumentError, "test adapter crash")
  defp maybe_crash(_request), do: :ok

  # Nothing is sent anywhere; the point is to exercise the two policy functions
  # so the fidelity record a real provider would produce also shows up here.
  defp simulate_upstream_request(request, api_key, client_headers) do
    body = Adapter.sanitize_request(request)
    # A real adapter records the finished body where it measures the payload;
    # the simulator does the same so the whole path stays testable.
    _payload_size_bytes = Adapter.record_outbound_body(body)
    {request_headers(api_key, client_headers), body}
  end
end
