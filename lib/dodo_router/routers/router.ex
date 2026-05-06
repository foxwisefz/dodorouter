defmodule DodoRouter.Routers.Router do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routers" do
    field :name, :string
    field :slug, :string
    field :api_key_hash, :string
    field :api_key_prefix, :string

    belongs_to :user, DodoRouter.Accounts.User
    has_many :routing_steps, DodoRouter.Routers.RoutingStep

    timestamps()
  end

  def changeset(router, attrs) do
    router
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
    |> maybe_derive_slug()
    |> validate_required(:slug)
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must be lowercase alphanumeric with dashes"
    )
    |> validate_length(:slug, min: 3, max: 50)
    |> unique_constraint(:slug)
    |> unique_constraint(:api_key_hash)
  end

  defp maybe_derive_slug(changeset) do
    if get_field(changeset, :slug) in ["", nil] do
      name = get_field(changeset, :name) || ""

      slug =
        name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s-]/, "")
        |> String.replace(~r/[\s_]+/, "-")
        |> String.trim("-")

      if slug != "" do
        put_change(changeset, :slug, slug)
      else
        changeset
      end
    else
      changeset
    end
  end

  def create_changeset(router, attrs) do
    {api_key, hash, prefix} = generate_api_key()

    router
    |> changeset(attrs)
    |> put_change(:api_key_hash, hash)
    |> put_change(:api_key_prefix, prefix)
    |> put_change(:api_key, api_key)
  end

  defp generate_api_key do
    prefix = "sk-dodo-"

    random_part =
      :crypto.strong_rand_bytes(24)
      |> Base.url_encode64(padding: false)

    full_key = prefix <> random_part
    hash = hash_api_key(full_key)
    display_prefix = String.slice(full_key, 0, 12)

    {full_key, hash, display_prefix}
  end

  def hash_api_key(key) do
    :crypto.hash(:sha256, key <> api_key_pepper())
    |> Base.encode64()
  end

  def verify_api_key(key, stored_hash) do
    hash_api_key(key) == stored_hash
  end

  defp api_key_pepper do
    secret =
      Application.fetch_env!(:dodo_router, DodoRouterWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.hash(:sha256, secret <> "api_key_pepper")
    |> binary_part(0, 32)
    |> Base.encode64()
  end
end
