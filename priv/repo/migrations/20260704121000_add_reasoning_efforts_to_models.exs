defmodule DodoRouter.Repo.Migrations.AddReasoningEffortsToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :reasoning_efforts, {:array, :string}, default: [], null: false
    end
  end
end
