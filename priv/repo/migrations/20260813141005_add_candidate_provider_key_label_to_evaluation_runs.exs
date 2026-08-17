defmodule DodoRouter.Repo.Migrations.AddCandidateProviderKeyLabelToEvaluationRuns do
  use Ecto.Migration

  # The candidate counterpart of judge_provider_key_label. The id column
  # already exists and nulls with the key (ON DELETE SET NULL), which loses
  # the last trace of which credential produced the answer being scored —
  # candidate_provider is the slug shared by every key of that provider, not
  # the key. The label is a snapshot taken at run time and outlives it.
  def up do
    alter table(:evaluation_runs) do
      add :candidate_provider_key_label, :string, null: true
    end

    # Backfill from the candidate replay's own log, which already records a
    # denormalized provider_key_label per attempt. Plain SQL: migrations run
    # under the OLD release and cannot call application code.
    execute """
    UPDATE evaluation_runs r
    SET candidate_provider_key_label = step.value ->> 'provider_key_label'
    FROM request_logs l
      CROSS JOIN LATERAL (
        SELECT value
        FROM jsonb_array_elements(l.attempted_steps)
        WHERE value ->> 'status' = 'success'
        ORDER BY (value ->> 'position')::int NULLS LAST
        LIMIT 1
      ) AS step
    WHERE r.candidate_log_id = l.id
      AND r.candidate_provider_key_label IS NULL
      AND step.value ->> 'provider_key_label' IS NOT NULL
    """
  end

  def down do
    alter table(:evaluation_runs) do
      remove :candidate_provider_key_label
    end
  end
end
