defmodule DodoRouter.Repo.Migrations.AddTruncationFlagsToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :truncation_flags, {:array, :string}, default: []
    end
  end
end
