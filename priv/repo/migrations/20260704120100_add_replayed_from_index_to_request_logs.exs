defmodule DodoRouter.Repo.Migrations.AddReplayedFromIndexToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Production recorded version 20260704120000 for a *different* migration
    # (add_reasoning_efforts_to_models shipped in 0.1.82-85 with a colliding
    # version number), so add_replayed_from_to_request_logs was silently
    # skipped there and the column may not exist yet — ensure it here.
    alter table(:request_logs) do
      add_if_not_exists :replayed_from_id,
                        references(:request_logs, type: :binary_id, on_delete: :nilify_all),
                        null: true
    end

    # An interrupted CREATE INDEX CONCURRENTLY leaves the index relation behind
    # (possibly INVALID) without recording this migration, and every retry then
    # fails with duplicate_table — so drop any leftover before creating.
    execute("DROP INDEX CONCURRENTLY IF EXISTS request_logs_replayed_from_id_index")

    create index(:request_logs, [:replayed_from_id],
             where: "replayed_from_id IS NOT NULL",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:request_logs, [:replayed_from_id],
                     where: "replayed_from_id IS NOT NULL",
                     concurrently: true
                   )
  end
end
