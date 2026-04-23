defmodule DodoRouter.Repo.Migrations.AddRequestHeadersToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :request_headers, :text
    end
  end
end
