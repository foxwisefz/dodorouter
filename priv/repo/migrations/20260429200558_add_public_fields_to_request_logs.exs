defmodule DodoRouter.Repo.Migrations.AddPublicFieldsToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :public_slug, :string
      add :published_at, :utc_datetime
      add :public_title, :string
      add :public_request_body, :text
      add :public_response_body, :text

      add :parent_log_id,
          references(:request_logs, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:request_logs, [:public_slug])
    create index(:request_logs, [:parent_log_id])
    create index(:request_logs, [:published_at])
  end
end
