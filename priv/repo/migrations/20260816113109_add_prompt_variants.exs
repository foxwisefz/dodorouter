defmodule DodoRouter.Repo.Migrations.AddPromptVariants do
  use Ecto.Migration

  def change do
    # Additive and nullable (hot-upgrade rules). jsonb so future variant
    # shapes (message patches, appends) need no further migration.
    alter table(:evaluations) do
      add :prompt_variants, {:array, :map}, null: true
    end

    alter table(:evaluation_runs) do
      add :variant_name, :string, null: true
    end
  end
end
