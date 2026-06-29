defmodule DodoRouter.Repo.Migrations.AddCachePricingToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :cache_read_price_per_million, :decimal
      add :cache_write_price_per_million, :decimal
    end
  end
end
