defmodule DodoRouter.Repo.Migrations.AddJudgeFeedbackToEvaluationRuns do
  use Ecto.Migration

  def change do
    alter table(:evaluation_runs) do
      # The judge's step-by-step assessment, produced before the score.
      add :reasoning, :text
      # What the judge found missing or ambiguous in the rubric — the
      # signal that an evaluation's criteria/examples need work.
      add :rubric_gaps, {:array, :text}, null: false, default: []
    end
  end
end
