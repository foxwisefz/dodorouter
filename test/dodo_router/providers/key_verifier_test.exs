defmodule DodoRouter.Providers.KeyVerifierTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Providers.KeyVerifier
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.ProvidersFixtures

  defp key_fixture(slug) do
    user = AccountsFixtures.user_fixture()
    ProvidersFixtures.provider_key_fixture(user, %{"provider_slug" => slug})
  end

  defp plug_returning(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end
  end

  test "probe styles per family" do
    assert KeyVerifier.probe_style("openai") == :openai_compat
    assert KeyVerifier.probe_style("zai_coding") == :openai_compat
    assert KeyVerifier.probe_style("anthropic") == :anthropic
    assert KeyVerifier.probe_style("google") == :google
    assert KeyVerifier.probe_style("openai-codex") == :skip_oauth_refresh
    assert KeyVerifier.probe_style("anthropic_oauth") == :skip
  end

  test "a 200 models listing verifies the key" do
    key = key_fixture("zai_standard")

    assert {:ok, :valid} =
             KeyVerifier.verify(key, plug: plug_returning(200, ~s({"data": []})))
  end

  test "a body-confirmed 401 is auth_invalid" do
    key = key_fixture("zai_standard")

    body = ~s({"error": {"code": "invalid_api_key", "message": "Incorrect API key"}})

    assert {:error, :auth_invalid, detail} =
             KeyVerifier.verify(key, plug: plug_returning(401, body))

    assert detail =~ "invalid_api_key"
  end

  test "a 503 is transient, never invalid" do
    key = key_fixture("zai_standard")

    assert {:error, :transient, _} =
             KeyVerifier.verify(key, plug: plug_returning(503, "overloaded"))
  end

  test "anthropic setup tokens are unverifiable by probe" do
    key = key_fixture("anthropic_oauth")
    assert {:ok, :unverifiable} = KeyVerifier.verify(key)
  end
end
