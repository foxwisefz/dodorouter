defmodule DodoRouter.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :api_key_hash, :string
    field :api_key_prefix, :string

    has_many :routing_steps, DodoRouter.Projects.RoutingStep

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/, message: "must be lowercase alphanumeric with dashes")
    |> validate_length(:slug, min: 3, max: 50)
    |> unique_constraint(:slug)
    |> unique_constraint(:api_key_hash)
  end

  def create_changeset(project, attrs) do
    {api_key, hash, prefix} = generate_api_key()

    project
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
