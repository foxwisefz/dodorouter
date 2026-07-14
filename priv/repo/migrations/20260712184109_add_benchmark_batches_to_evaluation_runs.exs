defmodule DodoRouter.Repo.Migrations.AddBenchmarkBatchesToEvaluationRuns do
  use Ecto.Migration

  def change do
    alter table(:evaluation_runs) do
      # Nullable: rows from before batching belong to an implicit legacy
      # batch, and old code must keep inserting during a hot upgrade.
      add :batch_id, :binary_id
      add :judge_cost_usd, :decimal
    end

    create index(:evaluation_runs, [:evaluation_id, :batch_id])

    alter table(:evaluations) do
      # The batch the most recent benchmark execution writes into; summary
      # and rankings aggregate only this batch. Nil = pre-batching data.
      add :last_batch_id, :binary_id
    end
  end
end
