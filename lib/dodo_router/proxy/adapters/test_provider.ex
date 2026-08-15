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

  # An evaluation's judge has to answer with a parseable judgement or every
  # run ends "failed" at the parse step, which makes the scored path — and
  # anything downstream of a score — untestable.
  @judge_model "judge-model"

  # Rate limiting is the one failure a caller is supposed to retry rather
  # than record, so a double that can only fail permanently cannot exercise
  # backoff at all. The "once" variant clears on the second call, which is
  # the difference between a retry that helps and one that just burns time.
  @rate_limited_model "rate-limited-model"
  @rate_limited_once_model "rate-limited-once-model"
  # An exhausted subscription, which Moonshot reports as 403 rather than
  # 402 or 429. Waiting does not fix it, so a caller must stop rather than
  # retry — the opposite response to @rate_limited_model.
  @quota_exhausted_model "quota-exhausted-model"
  # A retired snapshot: the provider understood the request perfectly and
  # refused it, which is not a gateway failure however much a blanket 502
  # made it look like one.
  @retired_model "retired-model"
  # A response that never reports usage, like a stream whose final usage
  # frame was missed — the cost columns must read unknown, not $0.
  @no_usage_model "no-usage-model"
  @call_table :dodo_test_provider_calls

  @impl Adapter
  def call(request, %RoutingStep{} = step, api_key, client_headers) do
    maybe_crash(request)
    _ = simulate_upstream_request(request, api_key, client_headers)

    case step.model do
      @failing_model ->
        simulated_failure()

      @rate_limited_model ->
        record_call(@rate_limited_model)
        rate_limited_failure()

      @rate_limited_once_model ->
        if record_call(@rate_limited_once_model) == 1,
          do: rate_limited_failure(),
          else: ok_response(step)

      @quota_exhausted_model ->
        record_call(@quota_exhausted_model)
        quota_exhausted_failure()

      @retired_model ->
        # Categorized the way a real adapter categorizes, so the double
        # exercises the classifier rather than dictating its own answer.
        {:error, Adapter.categorize_error(404, retired_body()),
         %{
           status: 404,
           body: Jason.encode!(retired_body()),
           latency_ms: 1
         }}

      _ ->
        ok_response(step)
    end
  end

  defp simulated_failure do
    {:error, :server_error, %{status: 500, body: "simulated failure", latency_ms: 1}}
  end

  @doc "Call count for a model, for tests asserting on retries."
  def call_count(model) do
    ensure_call_table()

    case :ets.lookup(@call_table, model) do
      [{^model, count}] -> count
      [] -> 0
    end
  end

  @doc "Clears the counter for one model. Per-model so async tests don't collide."
  def reset(model) do
    ensure_call_table()
    :ets.delete(@call_table, model)
    :ok
  end

  defp record_call(model) do
    ensure_call_table()
    :ets.update_counter(@call_table, model, {2, 1}, {model, 0})
  end

  defp ensure_call_table do
    case :ets.whereis(@call_table) do
      :undefined ->
        try do
          :ets.new(@call_table, [:named_table, :public, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp retired_body do
    %{
      "error" => %{"message" => "model: #{@retired_model}", "type" => "not_found_error"},
      "type" => "error"
    }
  end

  defp quota_exhausted_failure do
    {:error, :auth_error,
     %{
       status: 403,
       body:
         Jason.encode!(%{
           "error" => %{
             "message" => "You've reached your usage limit for this billing cycle",
             "type" => "access_terminated_error"
           }
         }),
       latency_ms: 1
     }}
  end

  defp rate_limited_failure do
    {:error, :rate_limited,
     %{
       status: 429,
       body: Jason.encode!(%{"error" => %{"message" => "Error", "type" => "rate_limit_error"}}),
       latency_ms: 1
     }}
  end

  @judgement %{
    "score" => 82,
    "summary" => "Answers the question directly",
    "reasoning" => "Checked each criterion against the reply.",
    "criterion_scores" => %{"accuracy" => 90, "brevity" => 74},
    "issues" => [],
    "rubric_gaps" => []
  }

  defp ok_response(step) do
    content =
      if step.model == @judge_model,
        do: Jason.encode!(@judgement),
        else: "Hello from #{step.model}"

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

    response = if step.model == @no_usage_model, do: Map.delete(response, "usage"), else: response

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
