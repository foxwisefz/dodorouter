defmodule DodoRouter.Providers.KeyHealthTrackingTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Providers
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.ProvidersFixtures

  defp key_fixture do
    user = AccountsFixtures.user_fixture()
    ProvidersFixtures.provider_key_fixture(user, %{"provider_slug" => "zai_standard"})
  end

  defp reload(key), do: Repo.get!(ProviderKey, key.id)

  # Mirrors the attempt maps FallbackChain builds
  defp attempt(key, overrides) do
    Map.merge(
      %{
        provider_key_id: key.id,
        provider: "zai",
        model: "glm-5",
        status: "error",
        error: "auth_error",
        http_status: 401,
        error_body: ~s({"error":{"code":"invalid_api_key","message":"Incorrect API key"}})
      },
      overrides
    )
  end

  test "a successful attempt marks the key valid" do
    key = key_fixture()

    Providers.record_attempts([attempt(key, %{status: "success", error: nil})])

    key = reload(key)
    assert key.status == "valid"
    assert key.last_ok_at
    refute key.last_error_class
  end

  test "a confirmed auth failure marks the key invalid with details" do
    key = key_fixture()

    Providers.record_attempts([attempt(key, %{})])

    key = reload(key)
    assert key.status == "invalid"
    assert key.last_error_class == "auth_invalid"
    assert key.last_error_detail =~ "invalid_api_key"
    assert key.last_error_at
  end

  test "quota errors mark quota_exceeded and a later 2xx self-heals" do
    key = key_fixture()

    Providers.record_attempts([
      attempt(key, %{http_status: 429, error: "rate_limited", error_body: "insufficient_quota"})
    ])

    assert reload(key).status == "quota_exceeded"

    Providers.record_attempts([attempt(key, %{status: "success", error: nil})])
    assert reload(key).status == "valid"
  end

  test "provider outages never flip a valid key" do
    key = key_fixture()
    Providers.record_attempts([attempt(key, %{status: "success", error: nil})])

    Providers.record_attempts([
      attempt(key, %{http_status: 503, error: "server_error", error_body: "overloaded"})
    ])

    key = reload(key)
    assert key.status == "valid"
    assert key.last_error_class == "transient"
  end

  test "steps without an assigned key are skipped" do
    assert :ok = Providers.record_attempts([%{provider_key_id: nil, status: "error"}])
  end

  test "only the terminal outcome per key counts" do
    key = key_fixture()

    Providers.record_attempts([
      attempt(key, %{http_status: 429, error_body: "rate limit"}),
      attempt(key, %{status: "success", error: nil})
    ])

    assert reload(key).status == "valid"
  end

  test "mark_key_verified stamps verified_at and clears errors" do
    key = key_fixture()
    Providers.record_attempts([attempt(key, %{})])
    assert reload(key).status == "invalid"

    Providers.mark_key_verified(key.id)

    key = reload(key)
    assert key.status == "valid"
    assert key.verified_at
    refute key.last_error_class
  end
end
