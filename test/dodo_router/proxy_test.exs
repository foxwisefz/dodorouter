defmodule DodoRouter.ProxyTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Proxy

  describe "error_response/1" do
    test "returns 400 with standardized context overflow error" do
      attempts = [
        %{error: "context_overflow", latency_ms: 100},
        %{error: "context_overflow", latency_ms: 150}
      ]

      {status, response} = Proxy.error_response(attempts)

      assert status == 400
      assert response.error.message == "Input exceeds context window of this model"
      assert response.error.type == "invalid_request_error"
      assert response.error.code == "context_length_exceeded"
      assert response.error.attempts == 2
    end

    test "returns 502 with generic provider error for non-context-overflow" do
      attempts = [
        %{error: "rate_limited", latency_ms: 100},
        %{error: "server_error", latency_ms: 150}
      ]

      {status, response} = Proxy.error_response(attempts)

      assert status == 502
      assert response.error.message == "All providers failed"
      assert response.error.type == "provider_error"
      assert response.error.last_error == "server_error"
      assert response.error.attempts == 2
    end

    test "handles single context overflow attempt" do
      attempts = [%{error: "context_overflow", latency_ms: 100}]

      {status, response} = Proxy.error_response(attempts)

      assert status == 400
      assert response.error.attempts == 1
    end
  end

  describe "streaming_error_payload/1" do
    test "returns context overflow payload for streaming" do
      attempts = [%{error: "context_overflow", latency_ms: 100}]

      payload = Proxy.streaming_error_payload(attempts)

      assert payload.error.message == "Input exceeds context window of this model"
      assert payload.error.type == "context_overflow"
    end

    test "returns generic failure payload for non-context-overflow" do
      attempts = [%{error: "timeout", latency_ms: 100}]

      payload = Proxy.streaming_error_payload(attempts)

      assert payload.error.message == "All providers failed"
      refute Map.has_key?(payload.error, :type)
    end
  end

  describe "truncate_body/1" do
    test "handles large text content truncation" do
      # Use text with spaces so it doesn't match base64 pattern
      large_content = String.duplicate("hello world ", 20_000)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => large_content}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_text_truncated" in flags
      assert String.length(truncated["messages"] |> hd() |> Map.get("content")) < 210_000
    end

    test "keeps large agent system prompts intact below the cap" do
      # Coding-agent system prompts routinely run 50-100KB; they must survive
      content = String.duplicate("agent instructions ", 5_000)

      request = %{"messages" => [%{"role" => "system", "content" => content}]}

      {truncated, flags} = Proxy.truncate_body(request)

      assert flags == []
      assert truncated["messages"] |> hd() |> Map.get("content") == content
    end

    test "handles base64 content truncation" do
      # Valid base64 string (length divisible by 4, only base64 chars)
      base64_content = String.duplicate("QUJD", 500)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => base64_content}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_base64_truncated" in flags
    end

    test "handles nil body" do
      {body, flags} = Proxy.truncate_body(nil)

      assert body == nil
      assert flags == []
    end

    test "leaves small content unchanged" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello world"}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert flags == []
      assert truncated["messages"] |> hd() |> Map.get("content") == "Hello world"
    end
  end

  describe "attempted_steps JSON serialization" do
    test "handles outbound_headers with tuples" do
      # Simulates what FallbackChain produces when adapters return headers as tuples
      attempted_steps = [
        %{
          provider: "moonshot",
          model: "kimi-k2",
          endpoint: "https://api.kimi.com/coding/v1/chat/completions",
          status: "success",
          latency_ms: 1234,
          outbound_headers: [
            {"Authorization", "Bearer sk-test"},
            {"Content-Type", "application/json"}
          ],
          response_headers: [
            {"content-type", "application/json"}
          ]
        }
      ]

      # This is what Proxy.log_request does before DB insert
      processed = Proxy.stringify_keys(attempted_steps)
      json = Jason.encode!(processed)
      decoded = Jason.decode!(json)

      step = hd(decoded)
      assert step["provider"] == "moonshot"

      assert step["outbound_headers"] == [
               ["Authorization", "Bearer sk-test"],
               ["Content-Type", "application/json"]
             ]

      assert step["response_headers"] == [["content-type", "application/json"]]
    end
  end

  describe "build_log_response_body/2" do
    test "uses successful response when present" do
      response = %{"choices" => [%{"message" => %{"content" => "Hello"}}]}
      last_step = %{error_body: nil}

      {body, flags} = Proxy.build_log_response_body(response, last_step)

      assert body["choices"] |> hd() |> get_in(["message", "content"]) == "Hello"
      assert flags == []
    end

    test "uses JSON error body from last step when no successful response" do
      error_json = ~s({"error": {"message": "Invalid key", "type": "auth_error"}})
      last_step = %{error_body: error_json}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body["error"]["message"] == "Invalid key"
      assert flags == []
    end

    test "uses map error body from last step" do
      last_step = %{error_body: %{"error" => %{"message" => "Rate limited"}}}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body["error"]["message"] == "Rate limited"
      assert flags == []
    end

    test "stores raw error string when JSON parsing fails" do
      raw_error = "not valid json at all"
      last_step = %{error_body: raw_error}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body["_raw_error"] == raw_error
      assert flags == []
    end

    test "returns nil when no error body exists" do
      last_step = %{}

      {body, flags} = Proxy.build_log_response_body(nil, last_step)

      assert body == nil
      assert flags == []
    end
  end
end
