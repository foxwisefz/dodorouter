defmodule DodoRouter.Repo.Migrations.AddRecordingToEvaluations do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Additive and nullable (hot-upgrade rules). Plain binary_id with no FK,
    # matching request_logs.recording_id: a deleted recording must not take
    # the benchmarks that were measured on it down with it.
    alter table(:evaluations) do
      add :recording_id, :binary_id, null: true
    end

    create index(:evaluations, [:recording_id], concurrently: true)
  end
end
