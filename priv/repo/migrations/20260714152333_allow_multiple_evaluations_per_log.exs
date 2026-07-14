defmodule DodoRouter.Repo.Migrations.AllowMultipleEvaluationsPerLog do
  use Ecto.Migration

  def up do
    # Leftover from the abandoned pre-benchmark evaluations schema: no
    # migration in this repo creates it, but databases that lived through
    # that era carry it. It limits a user to ONE evaluation per request
    # log, which duplication (and plain re-creation) must allow.
    # drop_if_exists keeps this a no-op on fresh databases.
    drop_if_exists unique_index(:evaluations, [:request_log_id, :evaluated_by_id])
  end

  # Not recreated on rollback: multiple evaluations per log may already
  # exist, so the unique index could no longer build.
  def down, do: :ok
end
