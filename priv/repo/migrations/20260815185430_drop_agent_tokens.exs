defmodule DodoRouter.Repo.Migrations.DropAgentTokens do
  use Ecto.Migration

  # Bearer agent tokens authenticated the REST agent surface. Both are gone:
  # agents connect over OAuth, which is the only credential mechanism now.
  #
  # Dropping rather than deprecating is safe *here* only because neither table
  # ever reached production — this whole surface was built and removed on the
  # same branch. The rule against dropping columns during a hot upgrade still
  # stands for anything that has actually shipped.
  #
  # agent_api_calls survives: it is the audit trail, and OAuth calls write to it.
  # Only its pointer at the retired credential goes, which nilifies nothing —
  # rows keep `principal_kind` and `principal_name`, so history stays readable.
  def up do
    alter table(:agent_api_calls) do
      remove :agent_token_id
    end

    drop table(:agent_tokens)
  end

  def down do
    create table(:agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :router_ids, {:array, :binary_id}, null: false, default: []
      add :all_routers, :boolean, null: false, default: false
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_tokens, [:token_hash])
    create index(:agent_tokens, [:user_id])

    alter table(:agent_api_calls) do
      add :agent_token_id, references(:agent_tokens, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
