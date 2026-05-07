defmodule DodoRouter.Repo.Migrations.AddFailOnContextOverflowToRouters do
  use Ecto.Migration

  def change do
    alter table(:routers) do
      add :fail_on_context_overflow, :boolean, default: false, null: false
    end
  end
end
