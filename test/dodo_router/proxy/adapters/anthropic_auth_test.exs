defmodule DodoRouter.Proxy.Adapters.AnthropicAuthTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.Anthropic

  test "OAuth setup-tokens authenticate with Bearer and the oauth beta header" do
    headers = Anthropic.auth_headers("sk-ant-oat01-abc123")

    assert {"authorization", "Bearer sk-ant-oat01-abc123"} in headers
    assert {"anthropic-beta", "oauth-2025-04-20"} in headers
    refute List.keymember?(headers, "x-api-key", 0)
  end

  test "API keys authenticate with x-api-key" do
    headers = Anthropic.auth_headers("sk-ant-api03-xyz")

    assert {"x-api-key", "sk-ant-api03-xyz"} in headers
    refute List.keymember?(headers, "authorization", 0)
    refute List.keymember?(headers, "anthropic-beta", 0)
  end

  test "the anthropic_oauth key slug is registered on the anthropic adapter" do
    alias DodoRouter.Proxy.Adapter.Registry

    assert "anthropic_oauth" in Registry.provider_slugs()
    assert Registry.adapter_provider("anthropic_oauth") == "anthropic"
    assert Registry.endpoint_for("anthropic_oauth") == "https://api.anthropic.com/v1"
  end
end
