defmodule DodoRouter.Providers do
  @moduledoc """
  Context for managing provider API keys.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Accounts.User

  @doc """
  Lists all provider keys for a user.
  """
  def list_provider_keys(%User{id: user_id}) do
    ProviderKey
    |> where(user_id: ^user_id)
    |> order_by([pk], [pk.provider_slug, pk.label])
    |> Repo.all()
  end

  @doc """
  Lists provider keys for a user, grouped by provider_slug.
  """
  def list_provider_keys_grouped(%User{} = user) do
    user
    |> list_provider_keys()
    |> Enum.group_by(& &1.provider_slug)
  end

  @doc """
  Gets a single provider key for a user.
  """
  def get_provider_key(%User{id: user_id}, id) do
    ProviderKey
    |> where(user_id: ^user_id, id: ^id)
    |> Repo.one()
  end

  @doc """
  Gets a provider key by ID. Raises if not found.
  """
  def get_provider_key!(%User{id: user_id}, id) do
    ProviderKey
    |> where(user_id: ^user_id, id: ^id)
    |> Repo.one!()
  end

  @doc """
  Creates a provider key and stores the API key in Infisical.
  """
  def create_provider_key(%User{id: user_id} = _user, attrs, api_key_value) do
    hint = generate_key_hint(api_key_value)
    do_create_provider_key(user_id, attrs, api_key_value, hint)
  end

  def create_provider_key_with_hint(%User{id: user_id}, attrs, api_key_value, hint) do
    do_create_provider_key(user_id, attrs, api_key_value, hint)
  end

  defp do_create_provider_key(user_id, attrs, api_key_value, hint) do
    changeset = ProviderKey.create_changeset(%ProviderKey{}, attrs, user_id, hint)

    case Repo.insert(changeset) do
      {:ok, provider_key} ->
        # Store the actual API key in Infisical
        case store_api_key(user_id, provider_key.key_ref, api_key_value) do
          :ok ->
            {:ok, provider_key}

          {:error, reason} ->
            # Rollback the database insert
            Repo.delete(provider_key)
            {:error, {:secret_storage_failed, reason}}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Replaces the raw secret for an existing provider key.
  """
  def update_provider_key_secret(%ProviderKey{user_id: user_id, key_ref: key_ref}, value) do
    store_api_key(user_id, key_ref, value)
  end

  @doc """
  Updates a provider key's metadata (label).
  Does not update the API key itself.
  """
  def update_provider_key(%ProviderKey{} = provider_key, attrs) do
    provider_key
    |> ProviderKey.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a provider key and its stored secret.
  """
  def delete_provider_key(%ProviderKey{} = provider_key) do
    # Delete from Infisical first
    delete_api_key(provider_key.user_id, provider_key.key_ref)

    # Then delete from database
    Repo.delete(provider_key)
  end

  @doc """
  Gets the raw API key value from Infisical for a provider key.
  """
  def get_raw_api_key(%ProviderKey{user_id: user_id, key_ref: key_ref}) do
    DodoRouter.Secrets.get_provider_key(user_id, key_ref)
  end

  def get_raw_api_key(nil), do: nil

  @doc """
  Resolves the usable API key for a provider key.

  For OAuth-based providers (e.g. OpenAI Codex), this decodes the stored
  credentials, refreshes the access token if needed, and returns the full
  encoded JSON credentials (so the adapter can extract the access token
  and account_id). For regular providers, returns the raw key as-is.
  """
  def resolve_api_key(%ProviderKey{provider_slug: "openai-codex"} = provider_key) do
    raw = get_raw_api_key(provider_key)

    case DodoRouter.OpenAICodexOAuth.ensure_access_token(provider_key, raw) do
      {:ok, _token, _account_id} ->
        # ensure_access_token refreshed and persisted; re-read the updated creds
        get_raw_api_key(provider_key)

      _ ->
        nil
    end
  end

  def resolve_api_key(%ProviderKey{} = provider_key) do
    get_raw_api_key(provider_key)
  end

  def resolve_api_key(nil), do: nil

  # Internal functions for Infisical storage

  defp store_api_key(user_id, key_ref, value) do
    DodoRouter.Secrets.put_provider_key(user_id, key_ref, value)
  end

  defp delete_api_key(user_id, key_ref) do
    DodoRouter.Secrets.delete_provider_key(user_id, key_ref)
  end

  # show bits of API key
  @doc false
  def generate_key_hint(nil), do: ""

  @doc false
  def generate_key_hint(key) do
    len = String.length(key)

    hint =
      cond do
        len <= 4 ->
          String.duplicate("•", len)

        len < 9 ->
          prefix = String.slice(key, 0, 2)
          bullets = String.duplicate("•", len - 2)
          prefix <> bullets

        len < 12 ->
          prefix = String.slice(key, 0, 3)
          bullets = String.duplicate("•", len - 3)
          prefix <> bullets

        true ->
          prefix = String.slice(key, 0, 3)
          suffix = String.slice(key, -3..-1//1)
          bullet_count = min(len - 6, 200)
          bullets = String.duplicate("•", bullet_count)
          "#{prefix}#{bullets}#{suffix}"
      end

    hint
  end
end
