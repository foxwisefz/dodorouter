defmodule DodoRouter.Repo.Migrations.AddCacheDiagnosticsToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :cache_fingerprint, :map
      add :cache_diagnosis, :map
    end
  end
end
