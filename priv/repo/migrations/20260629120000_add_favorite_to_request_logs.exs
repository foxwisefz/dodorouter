defmodule DodoRouter.Repo.Migrations.AddFavoriteToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :favorite, :boolean, default: false, null: false
    end
  end
end
