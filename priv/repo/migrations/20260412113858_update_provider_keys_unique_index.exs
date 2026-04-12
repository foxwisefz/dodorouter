defmodule DodoRouter.Repo.Migrations.UpdateProviderKeysUniqueIndex do
  use Ecto.Migration

  def change do
    # 1. Remove the old, restrictive index
    drop_if_exists index(:provider_keys, [:user_id, :label],
                     name: :provider_keys_user_id_label_index
                   )

    # 2. Create the new, more specific index
    create unique_index(:provider_keys, [:user_id, :provider_slug, :label],
             name: :provider_keys_user_id_provider_label_index
           )
  end
end
