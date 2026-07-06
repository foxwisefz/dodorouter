defmodule DodoRouter.Providers do
  @moduledoc """
  Context for managing provider API keys.
  """

  import Ecto.Query
  alias DodoRouter.Providers.KeyHealth
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
  @doc """
  Records key health from a completed proxy dispatch's attempted steps.

  Takes the terminal outcome per provider key (a request may retry the same
  key), classifies it, and applies the KeyHealth state machine with a
  targeted update_all — no read-modify-write, safe under concurrency.
  Steps without an assigned key (shared/legacy keys) are skipped.
  """
  def record_attempts(attempted_steps) when is_list(attempted_steps) do
    attempted_steps
    |> Enum.filter(& &1[:provider_key_id])
    |> Enum.group_by(& &1[:provider_key_id])
    |> Enum.each(fn {key_id, attempts} ->
      attempt = List.last(attempts)

      class =
        if attempt[:status] == "success" do
          :ok
        else
          KeyHealth.classify(
            attempt[:http_status],
            error_reason_atom(attempt[:error]),
            attempt[:error_body]
          )
        end

      apply_health(key_id, class, KeyHealth.error_detail(attempt[:error_body]))
    end)
  end

  def record_attempts(_), do: :ok

  @doc """
  Applies a health class to a key. Reads only the current status, then
  writes the transition via update_all keyed on that status so concurrent
  writers converge instead of clobbering.
  """
  def apply_health(key_id, class, detail \\ nil) do
    case Repo.one(from k in ProviderKey, where: k.id == ^key_id, select: {k.id, k.status}) do
      nil ->
        :ok

      {_id, current} ->
        {new_status, fields} = KeyHealth.transition(current, class)

        fields =
          fields
          |> Map.merge(if detail && class != :ok, do: %{last_error_detail: detail}, else: %{})
          |> Map.merge(if new_status == :unchanged, do: %{}, else: %{status: new_status})

        {_count, _} =
          Repo.update_all(
            from(k in ProviderKey, where: k.id == ^key_id),
            set: Map.to_list(fields)
          )

        :ok
    end
  end

  @doc "Marks a key as actively verified just now."
  def mark_key_verified(key_id) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(k in ProviderKey, where: k.id == ^key_id),
      set: [
        status: "valid",
        verified_at: now,
        last_error_class: nil,
        last_error_at: nil,
        last_error_detail: nil
      ]
    )

    :ok
  end

  defp error_reason_atom(nil), do: nil
  defp error_reason_atom("timeout"), do: :timeout
  defp error_reason_atom("network_error"), do: :network_error
  defp error_reason_atom(_), do: nil

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
          # Fixed-width mask: length-preserving bullets made long keys
          # overflow every UI element that renders a hint.
          prefix = String.slice(key, 0, 3)
          suffix = String.slice(key, -3..-1//1)
          "#{prefix}••••#{suffix}"
      end

    hint
  end

  @doc """
  Collapses bullet runs in key hints stored under the old length-preserving
  scheme, so existing rows display at the same fixed width as new ones.
  """
  def compact_key_hint(nil), do: ""
  def compact_key_hint(hint), do: String.replace(hint, ~r/•{5,}/u, "••••")
end
