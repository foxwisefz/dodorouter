defmodule DodoRouter.Repo.Migrations.AddReasoningEffortsToModels do
  use Ecto.Migration

  # Production already has this column: it originally shipped in 0.1.82-85
  # under version 20260704120000, which collided with
  # add_replayed_from_to_request_logs and forced a renumber to this version.
  # add_if_not_exists lets this record cleanly everywhere: no-op where the
  # column exists, real DDL on fresh databases.
  def up do
    alter table(:models) do
      add_if_not_exists :reasoning_efforts, {:array, :string}, default: [], null: false
    end
  end

  def down do
    alter table(:models) do
      remove_if_exists :reasoning_efforts
    end
  end
end
