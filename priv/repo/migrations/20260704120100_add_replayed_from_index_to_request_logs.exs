defmodule DodoRouter.Repo.Migrations.AddReplayedFromIndexToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Production recorded version 20260704120000 for a *different* migration
    # (add_reasoning_efforts_to_models shipped in 0.1.82-85 with a colliding
    # version number), so add_replayed_from_to_request_logs was silently
    # skipped there and the column may not exist yet — ensure it here.
    #
    # Raw SQL because ecto_sql's `add_if_not_exists` with `references` only
    # guards the column clause — the FK lands as an unguarded ADD CONSTRAINT,
    # which raises 42710 when a previous partial run already created it.
    execute("ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS replayed_from_id uuid")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'request_logs_replayed_from_id_fkey'
          AND conrelid = 'request_logs'::regclass
      ) THEN
        ALTER TABLE request_logs
          ADD CONSTRAINT request_logs_replayed_from_id_fkey
          FOREIGN KEY (replayed_from_id) REFERENCES request_logs(id) ON DELETE SET NULL;
      END IF;
    END $$
    """)

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
