defmodule DodoRouter.Repo.Migrations.WidenAgentApiCallTargetId do
  use Ecto.Migration

  # `target_id` was declared uuid because every target the table had when it
  # was written — a request log, an evaluation, a recording — carries one.
  # Sessions do not. A session id is whatever the client named it
  # ("question-7"), so every `get_session` audit row failed its insert and was
  # swallowed by the rescue in `Agents.record_call/1`: the tool an agent is
  # most likely to point at its own traffic was the one operation with no
  # audit trail at all.
  #
  # The column is deliberately type+id rather than a real association, which
  # already means it spans tables that share no key space. Text is the type
  # that says so; uuid was a guess that held for exactly as long as the
  # targets happened to be our own rows.
  #
  # A separate migration rather than an edit to 20260812224045, even though
  # that one has not shipped either: every dev and test database has already
  # recorded its version, and Ecto tracks by version alone, so editing it in
  # place would be a no-op everywhere it has already run — green locally,
  # wrong in the one database that mattered.
  #
  # Hot-upgrade-safe, for the reason that it is not interesting: the running
  # release has no `agent_api_calls` table and no `Agents.ApiCall` schema, so
  # both migrations land in the same deploy and no old code ever writes a uuid
  # into this column. If that ever stops being true — if the create migration
  # ships in an earlier release than this one — the old code would dump a raw
  # uuid binary against a text column and lose its audit rows to the rescue in
  # `Agents.record_call/1`, and this would need a full install.
  def up do
    execute "ALTER TABLE agent_api_calls ALTER COLUMN target_id TYPE text USING target_id::text"
  end

  def down do
    execute """
    ALTER TABLE agent_api_calls
      ALTER COLUMN target_id TYPE uuid
      USING CASE WHEN target_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                 THEN target_id::uuid END
    """
  end
end
