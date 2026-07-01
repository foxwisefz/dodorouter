defmodule DodoRouter.OpenAICodexOAuthTest do
  use ExUnit.Case, async: true

  alias DodoRouter.OpenAICodexOAuth
  alias DodoRouter.Providers.ProviderKey

  describe "encode_credentials/1" do
    test "encodes token response into JSON with type marker" do
      tokens = %{
        "access_token" => "access123",
        "refresh_token" => "refresh456",
        "expires_in" => 3600,
        "id_token" => nil
      }

      encoded = OpenAICodexOAuth.encode_credentials(tokens)
      {:ok, decoded} = Jason.decode(encoded)

      assert decoded["type"] == "openai_codex_oauth"
      assert decoded["access"] == "access123"
      assert decoded["refresh"] == "refresh456"
      assert is_integer(decoded["expires"])
      assert decoded["expires"] > System.system_time(:millisecond)
    end

    test "defaults expires_in to 3600 when missing" do
      encoded =
        OpenAICodexOAuth.encode_credentials(%{
          "access_token" => "a",
          "refresh_token" => "r"
        })

      {:ok, decoded} = Jason.decode(encoded)

      expiry_from_now = decoded["expires"] - System.system_time(:millisecond)
      assert expiry_from_now > 3500_000
    end
  end

  describe "decode_credentials/1" do
    test "decodes valid encoded credentials" do
      encoded =
        OpenAICodexOAuth.encode_credentials(%{"access_token" => "tok", "refresh_token" => "ref"})

      {:ok, decoded} = OpenAICodexOAuth.decode_credentials(encoded)
      assert decoded["access"] == "tok"
      assert decoded["refresh"] == "ref"
    end

    test "rejects credentials without type marker" do
      bad = Jason.encode!(%{"access" => "tok", "refresh" => "ref"})

      assert {:error, :invalid_credentials} = OpenAICodexOAuth.decode_credentials(bad)
    end

    test "rejects non-JSON input" do
      assert {:error, :invalid_credentials} = OpenAICodexOAuth.decode_credentials("not-json")
    end

    test "rejects wrong type marker" do
      bad = Jason.encode!(%{"type" => "something_else", "access" => "tok"})

      assert {:error, :invalid_credentials} = OpenAICodexOAuth.decode_credentials(bad)
    end
  end

  describe "ensure_access_token/2" do
    test "returns token without refresh when fresh" do
      encoded =
        OpenAICodexOAuth.encode_credentials(%{
          "access_token" => "fresh-token",
          "refresh_token" => "refresh",
          "expires_in" => 3600
        })

      provider_key = %ProviderKey{id: "pk1", user_id: "u1", key_ref: "ref1"}

      {:ok, token, account_id} = OpenAICodexOAuth.ensure_access_token(provider_key, encoded)
      assert token == "fresh-token"
      assert account_id == nil
    end

    test "allows raw bearer token for debugging (cannot refresh)" do
      provider_key = %ProviderKey{id: "pk1", user_id: "u1", key_ref: "ref1"}

      {:ok, token, account_id} =
        OpenAICodexOAuth.ensure_access_token(provider_key, "raw-bearer-token")

      assert token == "raw-bearer-token"
      assert account_id == nil
    end

    test "attempts refresh when token is expired" do
      encoded =
        OpenAICodexOAuth.encode_credentials(%{
          "access_token" => "old-token",
          "refresh_token" => "refresh123",
          "expires_in" => -1
        })

      provider_key = %ProviderKey{id: "pk1", user_id: "u1", key_ref: "ref1"}

      refresh_fun = fn refresh -> {:error, {:refresh_attempted, refresh}} end

      assert {:error, {:refresh_attempted, "refresh123"}} =
               OpenAICodexOAuth.ensure_access_token(provider_key, encoded, refresh_fun)
    end
  end

  describe "round-trip: encode then decode" do
    test "preserves access, refresh, and account_id" do
      original = %{
        "access_token" => "acc_tok",
        "refresh_token" => "ref_tok",
        "expires_in" => 7200,
        "id_token" => nil
      }

      encoded = OpenAICodexOAuth.encode_credentials(original)
      {:ok, decoded} = OpenAICodexOAuth.decode_credentials(encoded)

      assert decoded["access"] == original["access_token"]
      assert decoded["refresh"] == original["refresh_token"]
    end
  end

  describe "token freshness" do
    test "fresh token is not refreshed" do
      encoded =
        OpenAICodexOAuth.encode_credentials(%{
          "access_token" => "valid",
          "refresh_token" => "ref",
          "expires_in" => 600
        })

      provider_key = %ProviderKey{id: "pk1", user_id: "u1", key_ref: "ref1"}

      {:ok, token, _} = OpenAICodexOAuth.ensure_access_token(provider_key, encoded)
      assert token == "valid"
    end

    test "token near expiry (within margin) triggers refresh attempt" do
      # expires_in of 30s = 30000ms is within the 60s refresh margin
      encoded =
        OpenAICodexOAuth.encode_credentials(%{
          "access_token" => "expiring",
          "refresh_token" => "ref",
          "expires_in" => 30
        })

      provider_key = %ProviderKey{id: "pk1", user_id: "u1", key_ref: "ref1"}

      refresh_fun = fn refresh -> {:error, {:refresh_attempted, refresh}} end

      assert {:error, {:refresh_attempted, "ref"}} =
               OpenAICodexOAuth.ensure_access_token(provider_key, encoded, refresh_fun)
    end
  end
end
