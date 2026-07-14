defmodule DodoRouter.Repo.Migrations.MarkErroredCandidatesFailed do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE evaluation_runs AS er
    SET status = 'failed',
        score = NULL,
        passed = NULL,
        summary = NULL,
        criterion_scores = '{}'::jsonb,
        issues = '{}',
        error = COALESCE(er.error, 'Candidate provider returned an error'),
        updated_at = NOW()
    FROM request_logs AS rl
    WHERE er.candidate_log_id = rl.id
      AND rl.status = 'error'
      AND er.status = 'completed'
    """)
  end

  def down, do: :ok
end
