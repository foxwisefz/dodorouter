defmodule DodoRouter.Proxy.Adapters.TestProvider do
  @moduledoc """
  Test adapter for integration tests.

  Simulates an OpenAI-compatible provider for end-to-end testing.
  Calls send_chunk from a spawned process to mirror real adapter behavior
  (which invokes send_chunk from Finch's response callback process).
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

  @impl Adapter
  def call(_request, %RoutingStep{} = step, _api_key, _client_headers) do
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

    {:ok, response, %{headers: [{"content-type", "application/json"}]}}
  end

  @impl Adapter
  def stream(_request, %RoutingStep{} = step, _api_key, send_chunk, _client_headers) do
    content = "Hello from #{step.model}"

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

    {:ok, response, %{headers: [{"content-type", "text/event-stream"}]}}
  end
end
