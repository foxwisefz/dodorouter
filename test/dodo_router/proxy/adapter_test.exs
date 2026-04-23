defmodule DodoRouter.Proxy.AdapterTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter

  describe "build_forwarded_headers/2" do
    test "filters out proxy override headers (case-insensitive)" do
      client_headers = [
        {"Authorization", "Bearer old-key"},
        {"Content-Type", "text/plain"},
        {"Accept", "application/json"},
        {"X-Custom", "value"}
      ]

      proxy_headers = [
        {"Authorization", "Bearer new-key"},
        {"Content-Type", "application/json"}
      ]

      result = Adapter.build_forwarded_headers(client_headers, proxy_headers)

      assert {"Accept", "application/json"} in result
      assert {"X-Custom", "value"} in result
      assert {"Authorization", "Bearer new-key"} in result
      assert {"Content-Type", "application/json"} in result
      refute {"Authorization", "Bearer old-key"} in result
      refute {"Content-Type", "text/plain"} in result
    end

    test "returns proxy headers when client_headers is nil" do
      proxy_headers = [
        {"Authorization", "Bearer key"},
        {"Content-Type", "application/json"}
      ]

      result = Adapter.build_forwarded_headers(nil, proxy_headers)

      assert result == proxy_headers
    end

    test "returns proxy headers when client_headers is empty list" do
      proxy_headers = [{"Authorization", "Bearer key"}]

      result = Adapter.build_forwarded_headers([], proxy_headers)

      assert result == proxy_headers
    end

    test "passes through client headers that are not overrides" do
      client_headers = [
        {"X-Request-Id", "abc123"},
        {"Accept", "application/json"}
      ]

      proxy_headers = [{"Authorization", "Bearer key"}]

      result = Adapter.build_forwarded_headers(client_headers, proxy_headers)

      assert length(result) == 3
      assert {"X-Request-Id", "abc123"} in result
      assert {"Accept", "application/json"} in result
      assert {"Authorization", "Bearer key"} in result
    end

    test "filters override headers regardless of case" do
      client_headers = [
        {"authorization", "Bearer old"},
        {"AUTHORIZATION", "Bearer old2"},
        {"Content-Type", "text/html"}
      ]

      proxy_headers = [{"Authorization", "Bearer new"}]

      result = Adapter.build_forwarded_headers(client_headers, proxy_headers)

      assert length(result) == 1
      assert {"Authorization", "Bearer new"} in result
    end
  end
end
