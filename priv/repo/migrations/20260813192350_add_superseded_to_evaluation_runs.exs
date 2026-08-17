defmodule DodoRouter.Repo.Migrations.AddSupersededToEvaluationRuns do
  use Ecto.Migration

  # Retrying a failed run updates it in place, so the batch keeps one row per
  # measurement and its averages stay comparable. The cost was that the
  # attempt being replaced vanished — the record of *why* it failed the first
  # time was overwritten by the retry.
  #
  # So the old attempt is copied to a row of its own, stamped with when it
  # was superseded and by which run. Aggregates ignore superseded rows, which
  # is what keeps the batch honest; the page can still show them under the
  # run they belong to.
  def up do
    alter table(:evaluation_runs) do
      add :superseded_at, :utc_datetime_usec, null: true

      add :superseded_by_id,
          references(:evaluation_runs, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    # Every aggregate filters on this, so it is worth an index even on a
    # table this size — and partial, because live rows are the common read.
    create index(:evaluation_runs, [:superseded_by_id],
             where: "superseded_at IS NOT NULL",
             concurrently: false
           )
  end

  def down do
    alter table(:evaluation_runs) do
      remove :superseded_at
      remove :superseded_by_id
    end
  end
end
