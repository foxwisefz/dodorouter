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

      # Which routers this credential reaches. One app is usually several
      # routers (a router per module), so a token covers a set rather than
      # one — minting a credential per module would be friction with no
      # security gain, since they are the same app and the same agent.
      #
      # `all_routers` is a separate, explicit flag rather than "router_ids is
      # empty means everything". The difference matters: `all_routers` also
      # covers routers that do not exist yet, and that is a thing someone
      # should tick on purpose, not inherit from a null column. It is also
      # the only way to reach a *different* app's routers under the same
      # account, which is the blast radius worth making visible.
      #
      # No FK array constraint exists in Postgres; ownership is enforced in
      # DodoRouter.Agents.Principal, which has to check the owner anyway.
      add :router_ids, {:array, :binary_id}, null: false, default: []
      add :all_routers, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_tokens, [:token_hash])
    create index(:agent_tokens, [:user_id])
  end
end
