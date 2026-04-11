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

    belongs_to :user, DodoRouter.Accounts.User

    timestamps()
  end

  def changeset(provider_key, attrs) do
    provider_key
    |> cast(attrs, [:provider_slug, :label, :user_id])
    |> validate_required([:provider_slug, :label, :user_id])
    |> validate_inclusion(:provider_slug, @provider_slugs)
    |> validate_length(:label, min: 1, max: 100)
    |> unique_constraint([:user_id, :label])
    |> unique_constraint([:user_id, :key_ref])
    |> foreign_key_constraint(:user_id)
  end

  def create_changeset(provider_key, attrs, user_id) do
    key_ref = generate_key_ref()

    provider_key
    |> changeset(attrs)
    |> put_change(:user_id, user_id)
    |> put_change(:key_ref, key_ref)
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
