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

  describe "build_headers/2 (client identity forwarding)" do
    @client_headers [
      {"anthropic-beta",
       "claude-code-20250219,oauth-2025-04-20,context-1m-2025-08-07,extended-cache-ttl-2025-04-11"},
      {"user-agent", "claude-cli/2.1.218 (external, sdk-cli)"},
      {"x-app", "cli"},
      {"authorization", "Bearer sk-dodo-client-key"},
      {"x-api-key", "sk-dodo-client-key"},
      {"accept", "application/json"}
    ]

    test "forwards the client's anthropic-beta list verbatim (single header)" do
      headers = Anthropic.build_headers("sk-ant-oat01-abc", @client_headers)

      betas = for {"anthropic-beta", v} <- headers, do: v
      assert length(betas) == 1
      [beta] = betas
      assert beta =~ "claude-code-20250219"
      assert beta =~ "extended-cache-ttl-2025-04-11"
      assert beta =~ "oauth-2025-04-20"
    end

    test "appends the oauth beta for oat tokens when the client list lacks it" do
      client = [{"anthropic-beta", "claude-code-20250219"}]
      headers = Anthropic.build_headers("sk-ant-oat01-abc", client)

      [beta] = for {"anthropic-beta", v} <- headers, do: v
      assert beta == "claude-code-20250219,oauth-2025-04-20"
    end

    test "forwards user-agent and x-app" do
      headers = Anthropic.build_headers("sk-ant-oat01-abc", @client_headers)

      assert {"user-agent", "claude-cli/2.1.218 (external, sdk-cli)"} in headers
      assert {"x-app", "cli"} in headers
    end

    test "never forwards the client's credentials" do
      headers = Anthropic.build_headers("sk-ant-oat01-abc", @client_headers)

      assert {"authorization", "Bearer sk-ant-oat01-abc"} in headers
      refute Enum.any?(headers, fn {_k, v} -> is_binary(v) and v =~ "sk-dodo" end)
      refute List.keymember?(headers, "accept", 0)
    end

    test "without client headers behaves exactly like auth_headers" do
      assert Anthropic.build_headers("sk-ant-oat01-abc", []) ==
               Anthropic.auth_headers("sk-ant-oat01-abc")

      assert Anthropic.build_headers("sk-ant-api03-xyz", []) ==
               Anthropic.auth_headers("sk-ant-api03-xyz")
    end

    test "API keys get the client beta list without the oauth beta forced in" do
      client = [{"anthropic-beta", "claude-code-20250219"}]
      headers = Anthropic.build_headers("sk-ant-api03-xyz", client)

      [beta] = for {"anthropic-beta", v} <- headers, do: v
      assert beta == "claude-code-20250219"
      assert {"x-api-key", "sk-ant-api03-xyz"} in headers
    end
  end

  test "the anthropic_oauth key slug is registered on the anthropic adapter" do
    alias DodoRouter.Proxy.Adapter.Registry

    assert "anthropic_oauth" in Registry.provider_slugs()
    assert Registry.adapter_provider("anthropic_oauth") == "anthropic"
    assert Registry.endpoint_for("anthropic_oauth") == "https://api.anthropic.com/v1"
  end
end
