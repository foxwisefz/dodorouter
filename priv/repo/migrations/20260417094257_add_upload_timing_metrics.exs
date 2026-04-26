defmodule DodoRouter.Repo.Migrations.AddUploadTimingMetrics do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :payload_size_bytes, :integer
      add :upload_ms, :integer
      add :provider_processing_ms, :integer
    end
  end
end
