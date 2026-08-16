defmodule DodoRouter.Repo.Migrations.AddTokenAttributionToRequestLogs do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # One nullable jsonb column — hot-upgrade safe. Written at log time
    # (the decoded body is already in memory there); storing the small
    # bucket summary is what makes per-session aggregation a query over
    # kilobytes instead of a re-parse of megabytes. Rows from before the
    # column read as nil.
    alter table(:request_logs) do
      add :token_attribution, :map, null: true
    end
  end
end
