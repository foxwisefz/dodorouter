defmodule DodoRouter.Providers.KeyHealthTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Providers.KeyHealth

  describe "classify/3" do
    test "2xx is ok" do
      assert KeyHealth.classify(200, nil, nil) == :ok
      assert KeyHealth.classify(201, nil, %{}) == :ok
    end

    test "401/403 with confirming body text is auth_invalid" do
      body = ~s({"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}})
      assert KeyHealth.classify(401, nil, body) == :auth_invalid

      assert KeyHealth.classify(401, nil, %{"error" => %{"type" => "authentication_error"}}) ==
               :auth_invalid

      assert KeyHealth.classify(403, nil, "your organization has been disabled") == :auth_invalid
      assert KeyHealth.classify(403, nil, "API key revoked") == :auth_invalid
    end

    test "bare 401/403 without confirming body is unknown (could be a gateway)" do
      assert KeyHealth.classify(401, nil, nil) == :unknown
      assert KeyHealth.classify(403, nil, "Forbidden") == :unknown
    end

    test "quota and billing signals" do
      assert KeyHealth.classify(402, nil, nil) == :quota

      assert KeyHealth.classify(429, nil, %{"error" => %{"code" => "insufficient_quota"}}) ==
               :quota

      assert KeyHealth.classify(429, nil, "Your credit balance is too low") == :quota
    end

    test "plain 429 is rate_limit, not quota" do
      assert KeyHealth.classify(429, nil, "Rate limit reached, retry after 2s") == :rate_limit
    end

    test "5xx and timeouts are transient — provider outage is not a bad key" do
      assert KeyHealth.classify(500, nil, nil) == :transient
      assert KeyHealth.classify(503, nil, "overloaded") == :transient
      assert KeyHealth.classify(nil, :timeout, nil) == :transient
    end

    test "other 4xx are unknown" do
      assert KeyHealth.classify(400, nil, "bad request") == :unknown
      assert KeyHealth.classify(404, nil, nil) == :unknown
    end
  end

  describe "transition/2" do
    test "2xx is authoritative and heals any status" do
      for from <- [nil, "unverified", "valid", "invalid", "quota_exceeded", "unknown"] do
        assert {"valid", fields} = KeyHealth.transition(from, :ok)
        assert %{last_ok_at: %DateTime{}} = fields
      end
    end

    test "confirmed auth failure is sticky invalid" do
      assert {"invalid", fields} = KeyHealth.transition("valid", :auth_invalid)
      assert fields.last_error_class == "auth_invalid"
      # quota noise never rescues a confirmed-invalid key
      assert {:unchanged, _} = KeyHealth.transition("invalid", :quota)
    end

    test "quota flips valid to quota_exceeded" do
      assert {"quota_exceeded", _} = KeyHealth.transition("valid", :quota)
      assert {"quota_exceeded", _} = KeyHealth.transition(nil, :quota)
    end

    test "rate limits and transient errors only record, never flip" do
      assert {:unchanged, fields} = KeyHealth.transition("valid", :rate_limit)
      assert fields.last_error_class == "rate_limit"
      assert {:unchanged, _} = KeyHealth.transition("valid", :transient)
      assert {:unchanged, _} = KeyHealth.transition("quota_exceeded", :transient)
    end
  end
end
