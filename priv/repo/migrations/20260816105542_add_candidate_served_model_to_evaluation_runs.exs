defmodule DodoRouter.Repo.Migrations.AddCandidateServedModelToEvaluationRuns do
  use Ecto.Migration

  def change do
    alter table(:evaluation_runs) do
      # null: true, no default — additive per the hot-upgrade rules; old
      # rows read as "served model unknown".
      add :candidate_served_model, :string, null: true
    end
  end
end
