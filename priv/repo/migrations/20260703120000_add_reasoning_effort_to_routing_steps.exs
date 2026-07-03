defmodule DodoRouter.Repo.Migrations.AddReasoningEffortToRoutingSteps do
  use Ecto.Migration

  # Hot-upgrade safe: additive, nullable column. Old code running during a
  # deploy does not know about this field and inserts rows without it.
  def change do
    alter table(:routing_steps) do
      add :reasoning_effort, :string
    end
  end
end
