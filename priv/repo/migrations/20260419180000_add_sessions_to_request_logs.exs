defmodule DodoRouter.Repo.Migrations.AddSessionsToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :session_id, :string
      add :session_name, :string
    end

    create index(:request_logs, [:session_id])
    create index(:request_logs, [:router_id, :session_id])
  end
end
