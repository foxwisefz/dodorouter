defmodule DodoRouter.Repo.Migrations.AddBenchmarkStatusToEvaluations do
  use Ecto.Migration

  def change do
    alter table(:evaluations) do
      add :benchmark_status, :string, null: false, default: "draft"
    end
  end
end
