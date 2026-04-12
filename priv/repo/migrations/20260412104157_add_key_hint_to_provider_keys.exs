defmodule DodoRouter.Repo.Migrations.AddKeyHintToProviderKeys do
  use Ecto.Migration

  def change do
    alter table(:provider_keys) do
      add :key_hint, :string
    end
  end
end
