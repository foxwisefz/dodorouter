defmodule DodoRouter.Repo.Migrations.AddComparisonModeToEvaluations do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Additive and nullable (hot-upgrade rules). nil comparison_mode reads
    # as "rubric" — exactly how every existing evaluation behaves; nil
    # preference is a run whose judge was never asked for one.
    alter table(:evaluations) do
      add :comparison_mode, :text, null: true
    end

    alter table(:evaluation_runs) do
      add :preference, :text, null: true
    end
  end
end
