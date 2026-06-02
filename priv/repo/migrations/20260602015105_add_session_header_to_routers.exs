defmodule DodoRouter.Repo.Migrations.AddSessionHeaderToRouters do
  use Ecto.Migration

  def change do
    alter table(:routers) do
      add :session_header, :string, default: "x-session-id", null: false
    end
  end
end
