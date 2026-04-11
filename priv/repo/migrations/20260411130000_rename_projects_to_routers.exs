defmodule DodoRouter.Repo.Migrations.RenameProjectsToRouters do
  use Ecto.Migration

  def change do
    # Rename the main table
    rename table(:projects), to: table(:routers)

    # Rename the foreign key columns
    rename table(:routing_steps), :project_id, to: :router_id
    rename table(:request_logs), :project_id, to: :router_id
  end
end
