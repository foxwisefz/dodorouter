defmodule DodoRouter.Repo.Migrations.CreateRecordings do
  use Ecto.Migration

  def change do
    create table(:recordings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :status, :string, null: false, default: "recording"
      add :started_at, :utc_datetime_usec, null: false
      add :stopped_at, :utc_datetime_usec
      add :router_id, references(:routers, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:recordings, [:router_id])
    create index(:recordings, [:router_id, :status])

    alter table(:request_logs) do
      add :recording_id, :binary_id
    end

    create index(:request_logs, [:recording_id])
  end
end
