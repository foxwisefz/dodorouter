defmodule DodoRouter.Repo.Migrations.AddIdempotencyKeys do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # The reservation ledger behind Idempotency-Key: the unique index is the
    # concurrency guarantee (two racing requests with one key — exactly one
    # inserts and calls upstream). New table + two nullable columns, all
    # hot-upgrade safe.
    create table(:idempotency_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :router_id, references(:routers, type: :binary_id, on_delete: :delete_all), null: false

      add :key, :text, null: false
      # Rejecting a reused key with a different body needs the original
      # body's fingerprint, not the body itself.
      add :request_hash, :binary, null: false
      # Links the reservation to the request_logs row that holds the
      # replayable response.
      add :request_id, :binary_id, null: false
      add :status, :text, null: false, default: "in_progress"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_keys, [:router_id, :key], concurrently: true)

    alter table(:request_logs) do
      # Set on the original row when the client sent a key, and on every
      # replay row, which also points at the original it re-served —
      # zero-cost rows stay explainable.
      add :idempotency_key, :text, null: true
      add :idempotent_replay_of_id, :binary_id, null: true
    end
  end
end
