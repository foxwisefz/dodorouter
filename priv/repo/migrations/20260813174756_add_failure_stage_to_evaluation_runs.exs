defmodule DodoRouter.Repo.Migrations.AddFailureStageToEvaluationRuns do
  use Ecto.Migration

  # Which half of a run failed. A candidate that answered 200 and a judge
  # that then rate-limited produced exactly the same row as a candidate that
  # never answered — so a recoverable failure (re-judge the answer we
  # already paid for) was indistinguishable from a lost one.
  #
  # A new column rather than a new `status` value: old code keeps filtering
  # on status == "completed" / "failed" and simply ignores this, which is
  # what a hot upgrade needs.
  def up do
    alter table(:evaluation_runs) do
      add :failure_stage, :string, null: true
    end

    # Backfill from the candidate log: a failed run whose candidate call
    # succeeded can only have failed at the judge.
    execute """
    UPDATE evaluation_runs r
    SET failure_stage = CASE
      WHEN l.status IN ('success', 'fallback') THEN 'judge'
      ELSE 'candidate'
    END
    FROM request_logs l
    WHERE r.candidate_log_id = l.id
      AND r.status = 'failed'
      AND r.failure_stage IS NULL
    """

    # A failed run that never produced a candidate log never reached the
    # judge either.
    execute """
    UPDATE evaluation_runs
    SET failure_stage = 'candidate'
    WHERE status = 'failed' AND candidate_log_id IS NULL AND failure_stage IS NULL
    """
  end

  def down do
    alter table(:evaluation_runs) do
      remove :failure_stage
    end
  end
end
