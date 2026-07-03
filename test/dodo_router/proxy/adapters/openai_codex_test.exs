defmodule DodoRouter.Proxy.Adapters.OpenAICodexTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapters.OpenAICodex
  alias DodoRouter.Proxy.Adapter.Registry

  describe "adapter config" do
    test "registered with correct slug" do
      config = Registry.all_adapters()["openai-codex"]
      assert config != nil
      assert config.display_name == "OpenAI Codex"
      assert config.slug == "openai-codex"
      assert "openai-codex" in Registry.provider_slugs()
    end

    test "has codex models" do
      models = Registry.available_models("openai-codex")
      assert "gpt-5.5" in models
      assert "gpt-5.2" in models
    end
  end

  describe "parse_credentials/1" do
    test "extracts access token and account_id from JSON" do
      creds =
        Jason.encode!(%{
          "type" => "openai_codex_oauth",
          "access" => "eyJtoken123",
          "account_id" => "acc_456"
        })

      {token, account_id} = OpenAICodex.parse_credentials(creds)
      assert token == "eyJtoken123"
      assert account_id == "acc_456"
    end

    test "returns raw token with nil account_id for non-JSON" do
      {token, account_id} = OpenAICodex.parse_credentials("sk-raw-token")
      assert token == "sk-raw-token"
      assert account_id == nil
    end
  end
end
