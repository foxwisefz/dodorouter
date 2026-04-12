defmodule DodoRouter.Providers.ProviderKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @provider_slugs ~w(zai_standard zai_coding moonshot)

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
    |> validate_inclusion(:provider_slug, @provider_slugs)
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
    |> validate_inclusion(:provider_slug, @provider_slugs)
    |> validate_length(:label, max: 100)
    |> unique_constraint([:user_id, :key_ref])
    |> unique_constraint([:user_id, :label], name: "provider_keys_user_id_label_index")
    |> foreign_key_constraint(:user_id)
  end

  defp default_label(provider_slug) do
    info = display_info(provider_slug)
    "#{info.name} Key"
  end

  defp generate_key_ref do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  def provider_slugs, do: @provider_slugs

  @doc """
  Returns the base API endpoint URL for a provider slug.
  """
  def endpoint_for("zai_standard"), do: "https://api.z.ai/api/paas/v4"
  def endpoint_for("zai_coding"), do: "https://api.z.ai/api/coding/paas/v4"
  def endpoint_for("moonshot"), do: "https://api.moonshot.ai/v1"
  def endpoint_for(_), do: nil

  @doc """
  Returns display info for a provider slug.
  """
  def display_info("zai_standard"), do: %{name: "z.ai (Standard Plan)", provider: "zai"}
  def display_info("zai_coding"), do: %{name: "z.ai (Coding Plan)", provider: "zai"}
  def display_info("moonshot"), do: %{name: "Moonshot (Kimi)", provider: "moonshot"}
  def display_info(_), do: %{name: "Unknown", provider: nil}

  @doc """
  Maps old provider + plan_type to new provider_slug.
  """
  def to_slug("zai", "standard"), do: "zai_standard"
  def to_slug("zai", "coding"), do: "zai_coding"
  def to_slug("moonshot", _), do: "moonshot"
  def to_slug(provider, _), do: provider

  @doc """
  Extracts provider name from slug for adapter selection.
  """
  def adapter_provider("zai_standard"), do: "zai"
  def adapter_provider("zai_coding"), do: "zai"
  def adapter_provider("moonshot"), do: "moonshot"
  def adapter_provider(slug), do: slug
end
