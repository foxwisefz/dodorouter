defmodule DodoRouter.Repo.Migrations.CreateRouterApiKeys do
  use Ecto.Migration

  # This credential cutover requires stopped application instances; see the
  # multiple-key upgrade instructions in website/src/docs/deployment.md.

  def up do
    create table(:router_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :router_id, references(:routers, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :api_key_hash, :string, null: false
      add :api_key_prefix, :string, null: false
      add :revoked_at, :utc_datetime
      timestamps()
    end

    create unique_index(:router_api_keys, [:api_key_hash])
    create index(:router_api_keys, [:router_id])

    # Preserve the existing secret without needing its plaintext. Reusing the
    # router UUID as the initial key UUID avoids a database extension dependency.
    execute """
    INSERT INTO router_api_keys
      (id, router_id, name, api_key_hash, api_key_prefix, inserted_at, updated_at)
    SELECT id, id, 'Default', api_key_hash, api_key_prefix, inserted_at, updated_at
    FROM routers
    """
  end

  def down do
    drop table(:router_api_keys)
  end
end
