defmodule DodoRouter.Repo.Migrations.ReclassifyQuotaExhaustedKeys do
  use Ecto.Migration

  # KeyHealth.classify/3 only consulted the auth markers for 401/403, so a
  # provider that reports an exhausted subscription with 403 — Moonshot's
  # "You've reached your usage limit for this billing cycle" — was filed as
  # `unknown` and left the key reading "valid". The evidence was recorded
  # and then ignored, which is why a benchmark spent nineteen minutes
  # rediscovering it one failed call at a time.
  #
  # The classifier is fixed; this re-files what it already misjudged, so the
  # provider page and the new benchmark preflight tell the truth about keys
  # that failed before the fix shipped.
  def up do
    execute """
    UPDATE provider_keys
    SET status = 'quota_exceeded',
        last_error_class = 'quota'
    WHERE last_error_class = 'unknown'
      AND status IS DISTINCT FROM 'invalid'
      AND last_error_detail IS NOT NULL
      AND (
        last_error_detail ILIKE '%usage limit%'
        OR last_error_detail ILIKE '%access_terminated%'
        OR last_error_detail ILIKE '%billing%'
        OR last_error_detail ILIKE '%insufficient credits%'
        OR last_error_detail ILIKE '%insufficient_quota%'
        OR last_error_detail ILIKE '%quota exceeded%'
      )
    """
  end

  # A key wrongly marked exhausted is worse than one wrongly marked unknown,
  # so this reverses cleanly: back to what it was recorded as.
  def down do
    execute """
    UPDATE provider_keys
    SET status = 'valid', last_error_class = 'unknown'
    WHERE last_error_class = 'quota' AND last_error_detail ILIKE '%usage limit%'
    """
  end
end
