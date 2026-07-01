defmodule DodoRouter.Repo.Migrations.AddFavoriteIndexToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:request_logs, [:router_id, :inserted_at],
             where: "favorite = true",
             name: "request_logs_favorites_index",
             concurrently: true
           )
  end
end
