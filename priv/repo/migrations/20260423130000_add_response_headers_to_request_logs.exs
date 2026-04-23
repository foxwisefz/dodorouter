defmodule DodoRouter.Repo.Migrations.AddResponseHeadersToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add_if_not_exists :response_headers, :text
    end
  end
end
