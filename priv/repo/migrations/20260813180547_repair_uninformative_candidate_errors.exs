defmodule DodoRouter.Repo.Migrations.RepairUninformativeCandidateErrors do
  use Ecto.Migration

  # The old candidate message read only `error.message` from the provider's
  # body. Anthropic's rate-limit body carries the message "Error" and puts
  # the meaning in `type`, so a rate-limited run was recorded as, literally,
  # "Error" — and a 120s deadline of ours was recorded as "Candidate
  # provider returned an error (HTTP 502)", blaming the provider for a
  # timeout we imposed.
  #
  # Both are recoverable from the candidate log's own attempts, which record
  # the categorized reason per attempt.
  def up do
    execute """
    UPDATE evaluation_runs r
    SET error = CASE step.reason
      WHEN 'timeout' THEN 'Candidate timed out before answering'
      ELSE 'Candidate call ' || replace(step.reason, '_', ' ')
    END
    FROM request_logs l
      CROSS JOIN LATERAL (
        SELECT value ->> 'error' AS reason
        FROM jsonb_array_elements(l.attempted_steps)
        WHERE value ->> 'error' IS NOT NULL
        ORDER BY (value ->> 'position')::int DESC NULLS LAST
        LIMIT 1
      ) AS step
    WHERE r.candidate_log_id = l.id
      AND r.status = 'failed'
      AND r.failure_stage = 'candidate'
      AND (
        lower(coalesce(r.error, '')) IN ('', 'error', 'unknown')
        OR r.error LIKE 'Candidate provider returned an error%'
      )
    """
  end

  def down, do: :ok
end
