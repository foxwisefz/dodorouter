defmodule DodoRouter.Repo.Migrations.AddReplayedFromToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :replayed_from_id,
          references(:request_logs, type: :binary_id, on_delete: :nilify_all),
          null: true
    end
  end
end
