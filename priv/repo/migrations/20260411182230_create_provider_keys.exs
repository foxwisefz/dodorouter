defmodule DodoRouter.Repo.Migrations.CreateProviderKeys do
  use Ecto.Migration

  def change do
    create table(:provider_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :provider_slug, :string, null: false
      add :label, :string, null: false
      add :key_ref, :string, null: false

      timestamps()
    end

    create index(:provider_keys, [:user_id])
    create unique_index(:provider_keys, [:user_id, :label])
    create unique_index(:provider_keys, [:user_id, :key_ref])

    alter table(:routing_steps) do
      add :provider_key_id, references(:provider_keys, type: :uuid, on_delete: :nilify_all)
    end

    create index(:routing_steps, [:provider_key_id])
  end
end
