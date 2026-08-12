defmodule DodoRouter.Repo.Migrations.CreateAgentTokens do
  use Ecto.Migration

  # A credential for the agent surface, separate from a router's proxy key.
  #
  # The router key authenticates *sending traffic*; letting it also read back
  # stored prompts and responses turns a token-burning leak into a full
  # transcript leak. This table is the scoped, expiring, revocable credential
  # that replaces it there.
  #
  # New table, so this is hot-upgrade safe: the running release does not
  # reference it. Indexes are created inline rather than concurrently because
  # the table is empty at creation and cannot contend with anything.
  def change do
    create table(:agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # What this credential is for, in the user's words ("Claude Code on the
      # laptop"). An audit row naming a token is only useful if the token has
      # a name a human recognises.
      add :name, :string, null: false

      # Same shape as routers.api_key_hash/api_key_prefix: the secret itself is
      # never stored, only a peppered hash, plus a prefix for display so the UI
      # can tell two tokens apart without holding either.
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false

      add :scopes, {:array, :string}, null: false, default: []

      # Null means "never expires" — allowed, but the UI defaults to a date.
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      # Optional narrowing to one router. Null means every router the owner
      # has, which is the useful default for a coding agent working across a
      # product's dev and prod routers.
      add :router_id, references(:routers, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_tokens, [:token_hash])
    create index(:agent_tokens, [:user_id])
    create index(:agent_tokens, [:router_id])
  end
end
