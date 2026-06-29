defmodule DodoRouter.Repo.Migrations.AddCacheTokensToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :cache_read_tokens, :integer
      add :cache_write_tokens, :integer
    end
  end
end
