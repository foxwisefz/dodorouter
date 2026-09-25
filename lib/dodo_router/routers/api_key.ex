defmodule DodoRouter.Routers.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "router_api_keys" do
    field :name, :string
    field :api_key_hash, :string, redact: true
    field :api_key_prefix, :string
    field :revoked_at, :utc_datetime
    belongs_to :router, DodoRouter.Routers.Router
    timestamps()
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:api_key_hash)
    |> foreign_key_constraint(:router_id)
  end
end
