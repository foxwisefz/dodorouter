defmodule DodoRouter.Repo.Migrations.AddMultiLogEvaluations do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Additive and nullable throughout (hot-upgrade rules). request_log_id
    # stays required as the anchor (= first of the set); source_log_ids nil
    # or [] reads as [request_log_id].
    alter table(:evaluations) do
      add :source_log_ids, {:array, :binary_id}, null: true
    end

    alter table(:evaluation_runs) do
      add :source_log_id,
          references(:request_logs, on_delete: :nilify_all, type: :binary_id),
          null: true
    end

    create index(:evaluation_runs, [:source_log_id], concurrently: true)
  end
end
