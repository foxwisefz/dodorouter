defmodule DodoRouter.Repo.Migrations.CreateRoutingChangeEvents do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # The auditable link between a routing change and the benchmark batch
    # that justified it. New table — hot-upgrade safe. routing_step_id,
    # evaluation_id and changed_by_id are plain ids on purpose: the audit
    # row must outlive a deleted step, evaluation, or account, or the
    # decision it records stops being auditable exactly when someone asks.
    create table(:routing_change_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :router_id, references(:routers, type: :binary_id, on_delete: :delete_all), null: false

      add :routing_step_id, :binary_id, null: false
      add :evaluation_id, :binary_id
      add :batch_id, :binary_id
      add :changed_by_id, :binary_id, null: false
      add :before_step, :map, null: false
      add :after_step, :map, null: false
      add :reverted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create index(:routing_change_events, [:router_id], concurrently: true)
    create index(:routing_change_events, [:evaluation_id], concurrently: true)
  end
end
