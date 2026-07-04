defmodule DodoRouter.Repo.Migrations.AddReplayedFromIndexToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:request_logs, [:replayed_from_id],
             where: "replayed_from_id IS NOT NULL",
             concurrently: true
           )
  end
end
