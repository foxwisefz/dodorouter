defmodule DodoRouter.Repo.Migrations.AddUserToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create index(:projects, [:user_id])
  end
end
