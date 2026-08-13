defmodule DodoRouter.Repo.Migrations.AddJudgeProviderKeyToEvaluationRuns do
  use Ecto.Migration

  # A run records the judge key that actually produced it. The evaluation's
  # own judge_provider_key_id is forward-looking — what a re-run will use —
  # and can be repointed at another key or emptied when one is deleted;
  # neither may rewrite what a past run says judged it.
  #
  # The id nulls with the key (ON DELETE SET NULL). The label is a snapshot
  # taken at run time and outlives it, which is what lets a reader tell a
  # deleted judge (label, no id) from a run recorded before this existed
  # (neither).
  def up do
    alter table(:evaluation_runs) do
      add :judge_provider_key_id,
          references(:provider_keys, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :judge_provider_key_label, :string, null: true
    end

    # Backfill from the judge call's own log. attempted_steps carries a
    # denormalized provider_key_id/label snapshot per attempt, so this is
    # accurate even for runs whose key is already gone — and it is plain SQL
    # because migrations run under the OLD release, without this one's code.
    execute """
    UPDATE evaluation_runs r
    SET judge_provider_key_label = step.value ->> 'provider_key_label',
        judge_provider_key_id = CASE
          WHEN pk.id IS NOT NULL THEN pk.id
          ELSE NULL
        END
    FROM request_logs l
      CROSS JOIN LATERAL (
        SELECT value
        FROM jsonb_array_elements(l.attempted_steps)
        WHERE value ->> 'status' = 'success'
        ORDER BY (value ->> 'position')::int NULLS LAST
        LIMIT 1
      ) AS step
      LEFT JOIN provider_keys pk
        ON pk.id = (step.value ->> 'provider_key_id')::uuid
    WHERE r.judge_log_id = l.id
      AND r.judge_provider_key_label IS NULL
      AND step.value ->> 'provider_key_label' IS NOT NULL
    """
  end

  def down do
    alter table(:evaluation_runs) do
      remove :judge_provider_key_id
      remove :judge_provider_key_label
    end
  end
end
