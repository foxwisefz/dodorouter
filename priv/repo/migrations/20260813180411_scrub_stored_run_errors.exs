defmodule DodoRouter.Repo.Migrations.ScrubStoredRunErrors do
  use Ecto.Migration

  # Rows written before evaluation_runs.error was built from named fields
  # hold `inspect/1` of the whole attempts list. That list carries
  # outbound_headers, so nine of these rows contained a working provider
  # credential — rendered verbatim on the evaluation page — and the longest
  # was 10,706 characters shown as a run's one-line subtitle.
  #
  # Rewriting rather than blanking: the provider and the reason are in there
  # and are the whole diagnostic value, so they are pulled back out with a
  # regex and everything else is dropped.
  def up do
    execute """
    UPDATE evaluation_runs
    SET error =
      (CASE WHEN failure_stage = 'judge' THEN 'Judge call failed — ' ELSE '' END)
      || 'every provider failed ('
      || coalesce(
           (SELECT string_agg(DISTINCT m[1], ', ')
            FROM regexp_matches(error, 'provider: "([a-z0-9_-]+)"', 'g') AS m),
           'provider not recorded')
      || ': '
      || coalesce(
           (SELECT string_agg(DISTINCT replace(m[1], '_', ' '), ', ')
            FROM regexp_matches(error, 'error: "([a-z_]+)"', 'g') AS m),
           'reason not recorded')
      || ')'
    WHERE error LIKE '%all_providers_failed%'
    """

    # Belt and braces: anything left anywhere in this column that looks like
    # a credential is replaced, and the column is capped.
    execute """
    UPDATE evaluation_runs
    SET error = regexp_replace(
      regexp_replace(error, 'Bearer\\s+[A-Za-z0-9\\-._~+/]{10,}=*', '[REDACTED]', 'g'),
      'sk-[A-Za-z0-9\\-_]{20,}', '[REDACTED]', 'g'
    )
    WHERE error ~ 'Bearer\\s+[A-Za-z0-9\\-._~+/]{10,}' OR error ~ 'sk-[A-Za-z0-9\\-_]{20,}'
    """

    execute """
    UPDATE evaluation_runs
    SET error = left(error, 1985) || ' … [truncated]'
    WHERE length(error) > 2000
    """

    # Three request logs from before outbound headers were redacted on the
    # write path still hold a raw key in attempted_steps.
    execute """
    UPDATE request_logs
    SET attempted_steps = regexp_replace(
      attempted_steps::text, 'Bearer sk-[A-Za-z0-9\\-_]{6,}', 'Bearer [REDACTED]', 'g'
    )::jsonb
    WHERE attempted_steps::text ~ 'Bearer sk-[A-Za-z0-9\\-_]{6,}'
    """
  end

  # Irreversible on purpose: the point was to destroy the secrets.
  def down, do: :ok
end
