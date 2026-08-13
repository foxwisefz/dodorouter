defmodule DodoRouter.Repo.Migrations.BackfillProviderKeyLabelsFromFailedAttempts do
  use Ecto.Migration

  # The two preceding backfills only read attempts with status 'success', so
  # every run whose candidate or judge call failed outright stayed null and
  # read as "unknown". That is wrong: a failed attempt still names the key it
  # authenticated with, and "which key failed?" is exactly the question a
  # failed run raises. This fills the remainder from the last attempt made.
  #
  # Idempotent (only touches NULLs) and additive, so it is safe to run after
  # the earlier ones rather than editing them.
  def up do
    execute backfill("candidate_provider_key_label", "candidate_log_id")
    execute backfill("judge_provider_key_label", "judge_log_id")
  end

  def down, do: :ok

  # Prefer the attempt that served; otherwise the last one tried, which is
  # the provider that produced the error the run recorded.
  defp backfill(label_column, log_column) do
    """
    UPDATE evaluation_runs r
    SET #{label_column} = step.value ->> 'provider_key_label'
    FROM request_logs l
      CROSS JOIN LATERAL (
        SELECT value
        FROM jsonb_array_elements(l.attempted_steps)
        WHERE value ->> 'provider_key_label' IS NOT NULL
        ORDER BY (value ->> 'status' = 'success') DESC,
                 (value ->> 'position')::int DESC NULLS LAST
        LIMIT 1
      ) AS step
    WHERE r.#{log_column} = l.id
      AND r.#{label_column} IS NULL
    """
  end
end
