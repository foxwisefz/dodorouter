defmodule DodoRouter.ProvidersFixtures do
  @moduledoc """
  Test helpers for creating provider key entities.

  Provider keys created here are seeded into the `:dodo_secrets_cache` ETS
  table so `Providers.resolve_api_key/1` works without Infisical.
  """

  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Repo

  def provider_key_fixture(user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"provider_slug" => "test_provider", "label" => "test key"},
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    provider_key =
      %ProviderKey{}
      |> ProviderKey.create_changeset(attrs, user.id, "sk-testkey")
      |> Repo.insert!()

    seed_secrets_cache(user.id, provider_key.key_ref, "test-api-key")

    provider_key
  end

  def seed_secrets_cache(user_id, key_ref, api_key) do
    ensure_cache_table()

    cache_key = "provider_key/#{user_id}/#{key_ref}"
    expires_at = System.system_time(:millisecond) + 3_600_000
    :ets.insert(:dodo_secrets_cache, {cache_key, api_key, expires_at})
  end

  defp ensure_cache_table do
    case :ets.whereis(:dodo_secrets_cache) do
      :undefined ->
        try do
          :ets.new(:dodo_secrets_cache, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
