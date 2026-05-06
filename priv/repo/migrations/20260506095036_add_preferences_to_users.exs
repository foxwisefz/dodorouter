defmodule DodoRouter.Repo.Migrations.AddPreferencesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :sidebar_collapsed, :boolean, default: false, null: false
      add :theme, :string, default: "light", null: false
    end
  end
end
