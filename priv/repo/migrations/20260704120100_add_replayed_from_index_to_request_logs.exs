defmodule DodoRouter.Repo.Migrations.AddReplayedFromIndexToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # An interrupted CREATE INDEX CONCURRENTLY leaves the index relation behind
  # (possibly INVALID) without recording this migration, and every retry then
  # fails with duplicate_table — so drop any leftover before creating.
  def up do
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
