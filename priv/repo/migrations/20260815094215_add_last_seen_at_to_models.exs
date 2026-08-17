defmodule DodoRouter.Repo.Migrations.AddLastSeenAtToModels do
  use Ecto.Migration

  # models.dev publishes no deprecation field of any kind — a retired model
  # is simply absent from api.json. So "present in the last sync" is the only
  # retirement signal there is, and this column is how we hold it.
  #
  # Backfilled to the row's own updated_at, which is when the last sync that
  # touched it ran. Not to `now()`: that would claim every long-retired model
  # was seen this minute, which is the opposite of what the column is for.
  def up do
    alter table(:models) do
      add :last_seen_at, :utc_datetime_usec, null: true
    end

    execute "UPDATE models SET last_seen_at = updated_at"

    create index(:models, [:last_seen_at])
  end

  def down do
    alter table(:models) do
      remove :last_seen_at
    end
  end
end
