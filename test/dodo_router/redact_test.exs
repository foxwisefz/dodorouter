defmodule DodoRouter.RedactTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Redact

  describe "redact_secrets/1" do
    test "redacts Bearer tokens" do
      assert Redact.redact_secrets("Bearer abc123def456ghi789") == "[REDACTED]"
    end

    test "redacts Basic auth" do
      assert Redact.redact_secrets("Basic dXNlcjpwYXNzd29yZA==") == "[REDACTED]"
    end

    test "redacts sk- prefixed keys" do
      assert Redact.redact_secrets("sk-abcdefghij1234567890") == "[REDACTED]"
      assert Redact.redact_secrets("key: sk-proj-abc123def456ghi789jkl") == "key: [REDACTED]"
    end

    test "redacts JWTs" do
      jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature"
      assert Redact.redact_secrets(jwt) == "[REDACTED]"
    end

    test "redacts api_key patterns" do
      assert Redact.redact_secrets("api_key=secretvalue123") == "[REDACTED]"
      assert Redact.redact_secrets("api-key: mysecretkey123") == "[REDACTED]"
    end

    test "redacts AWS access key IDs" do
      assert Redact.redact_secrets("AKIAIOSFODNN7EXAMPLE") == "[REDACTED]"
      assert Redact.redact_secrets("ASIAXYZ123456789ABCD") == "[REDACTED]"
    end

    test "redacts Google API keys" do
      assert Redact.redact_secrets("AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe") == "[REDACTED]"
    end

    test "redacts GCP OAuth tokens" do
      assert Redact.redact_secrets("ya29.a0ARrdaM8_some_long_token_here") == "[REDACTED]"
    end

    test "leaves non-secret strings unchanged" do
      assert Redact.redact_secrets("application/json") == "application/json"
      assert Redact.redact_secrets("hello world") == "hello world"
      assert Redact.redact_secrets("content-type") == "content-type"
    end

    test "handles nil and non-strings" do
      assert Redact.redact_secrets(nil) == nil
      assert Redact.redact_secrets(123) == 123
    end
  end

  describe "redact_headers/1" do
    test "redacts authorization header by key" do
      headers = [{"authorization", "Bearer token123"}]
      assert Redact.redact_headers(headers) == [{"authorization", "[REDACTED]"}]
    end

    test "redacts cookie headers by key" do
      headers = [{"cookie", "session=abc123"}]
      assert Redact.redact_headers(headers) == [{"cookie", "[REDACTED]"}]
    end

    test "redacts x-api-key header by key" do
      headers = [{"x-api-key", "my-secret-key"}]
      assert Redact.redact_headers(headers) == [{"x-api-key", "[REDACTED]"}]
    end

    test "redacts secrets in other header values" do
      headers = [{"x-custom", "token sk-abc123def456ghi789jkl"}]
      assert Redact.redact_headers(headers) == [{"x-custom", "token [REDACTED]"}]
    end

    test "leaves safe headers unchanged" do
      headers = [{"content-type", "application/json"}, {"accept", "text/html"}]
      assert Redact.redact_headers(headers) == headers
    end

    test "handles map format (Req response headers)" do
      headers = %{"content-type" => ["application/json"], "authorization" => ["Bearer xyz"]}
      result = Redact.redact_headers(headers)
      assert {"authorization", "[REDACTED]"} in result
      assert {"content-type", "application/json"} in result
    end

    test "handles nil" do
      assert Redact.redact_headers(nil) == nil
    end
  end
end
