defmodule DodoRouter.Repo.Migrations.AddBillingFieldsToUsers do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:users) do
      add :stripe_customer_id, :string, null: true
      add :stripe_subscription_id, :string, null: true
      add :subscription_status, :string, null: true
      add :subscription_current_period_end, :utc_datetime, null: true
    end

    create unique_index(:users, [:stripe_customer_id], concurrently: true)
  end
end
