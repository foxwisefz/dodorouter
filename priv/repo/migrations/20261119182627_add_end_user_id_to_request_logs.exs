defmodule DodoRouter.Repo.Migrations.AddEndUserIdToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:request_logs) do
      add :end_user_id, :string, null: true
    end

    create index(:request_logs, [:router_id, :end_user_id, :inserted_at],
             where: "end_user_id IS NOT NULL",
             concurrently: true
           )
  end
end
