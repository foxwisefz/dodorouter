defmodule DodoRouter.Repo.Migrations.ExpandEvaluationsIntoBenchmarks do
  use Ecto.Migration

  def change do
    alter table(:evaluations) do
      add :candidate_targets, {:array, :map}, null: false, default: []
      add :repetitions, :integer, null: false, default: 3
    end

    alter table(:evaluation_runs) do
      add :candidate_provider_key_id,
          references(:provider_keys, type: :binary_id, on_delete: :nilify_all)

      add :candidate_provider, :string
      add :candidate_model, :string
      add :repetition, :integer
      add :candidate_log_id, references(:request_logs, type: :binary_id, on_delete: :nilify_all)
      add :candidate_latency_ms, :integer
      add :candidate_cost_usd, :decimal
      add :candidate_output, :text
    end

    create index(:evaluation_runs, [:evaluation_id, :candidate_model])
  end
end
