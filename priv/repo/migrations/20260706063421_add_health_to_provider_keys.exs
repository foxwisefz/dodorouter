defmodule DodoRouter.Repo.Migrations.AddHealthToProviderKeys do
  use Ecto.Migration

  # Additive-only for hot-upgrade safety: nullable, no defaults.
  # NULL status means "unverified" in application code.
  def change do
    alter table(:provider_keys) do
      add :status, :string
      add :verified_at, :utc_datetime_usec
      add :last_ok_at, :utc_datetime_usec
      add :last_error_class, :string
      add :last_error_at, :utc_datetime_usec
      add :last_error_detail, :string
    end
  end
end
