defmodule DodoRouter.Providers.ProviderKey do
  use Ecto.Schema
  import Ecto.Changeset

  alias DodoRouter.Proxy.Adapter.Registry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "provider_keys" do
    field :provider_slug, :string
    field :label, :string
    field :key_ref, :string
    field :key_hint, :string

    belongs_to :user, DodoRouter.Accounts.User

    timestamps()
  end

  def changeset(provider_key, attrs) do
    provider_key
    |> cast(attrs, [:provider_slug, :label, :user_id])
    |> validate_required([:provider_slug])
    |> validate_inclusion(:provider_slug, Registry.provider_slugs())
    |> validate_length(:label, max: 100)
    |> unique_constraint([:user_id, :key_ref])
    |> foreign_key_constraint(:user_id)
  end

  def create_changeset(provider_key, attrs, user_id, key_hint) do
    key_ref = generate_key_ref()
    provider_slug = attrs[:provider_slug] || attrs["provider_slug"]

    # Generate default label if not provided
    label =
      case attrs[:label] || attrs["label"] do
        nil -> default_label(provider_slug)
        "" -> default_label(provider_slug)
        l -> l
      end

    provider_key
    |> cast(attrs, [:provider_slug, :label])
    |> put_change(:key_hint, key_hint)
    |> put_change(:label, label)
    |> put_change(:user_id, user_id)
    |> put_change(:key_ref, key_ref)
    |> validate_required([:provider_slug, :user_id])
    |> validate_inclusion(:provider_slug, Registry.provider_slugs())
    |> validate_length(:label, max: 100)
    |> unique_constraint([:user_id, :key_ref])
    |> unique_constraint([:user_id, :provider_slug, :label],
      name: :provider_keys_user_id_provider_label_index
    )
    |> foreign_key_constraint(:user_id)
  end

  defp default_label(provider_slug) do
    info = display_info(provider_slug)
    "#{info.name} Key"
  end

  defp generate_key_ref do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  def provider_slugs, do: Registry.provider_slugs()

  @doc """
  Returns the base API endpoint URL for a provider slug.
  """
  def endpoint_for(key_slug), do: Registry.endpoint_for(key_slug)

  @doc """
  Returns display info for a provider slug.
  """
  def display_info(key_slug), do: Registry.display_info(key_slug)

  @doc """
  Maps old provider + plan_type to new provider_slug.
  """
  def to_slug(provider, plan_type), do: Registry.to_key_slug(provider, plan_type)

  @doc """
  Extracts provider name from slug for adapter selection.
  """
  def adapter_provider(key_slug), do: Registry.adapter_provider(key_slug)
end
