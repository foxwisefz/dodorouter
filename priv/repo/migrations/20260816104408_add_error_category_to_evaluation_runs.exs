defmodule DodoRouter.Repo.Migrations.AddErrorCategoryToEvaluationRuns do
  use Ecto.Migration

  def change do
    alter table(:evaluation_runs) do
      # null: true and no default — old code ignores it, old rows read as
      # "category unknown" rather than a fabricated value (hot-upgrade rule).
      add :error_category, :string, null: true
    end
  end
end
