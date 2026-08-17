defmodule DodoRouter.Repo.Migrations.CreateOauthClients do
  use Ecto.Migration

  # attesto deliberately does not own a client registry — it resolves clients
  # through host callbacks — so the registry is ours.
  #
  # It exists mainly for Dynamic Client Registration (RFC 7591): an assistant
  # like Claude Code has no way to pre-register, so it registers itself at
  # first contact and we have to persist what it claimed.
  def change do
    create table(:oauth_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The OAuth client_id. Issued unprefixed by RFC 7591 §3.2.1, so it is a
      # plain string rather than our usual uuid.
      add :client_id, :string, null: false
      add :client_name, :string

      # Public clients (PKCE, no secret) are the normal case for a desktop
      # agent; a confidential client stores only a hash.
      add :public, :boolean, null: false, default: true
      add :client_secret_hash, :string

      add :redirect_uris, {:array, :string}, null: false, default: []
      add :grant_types, {:array, :string}, null: false, default: []

      # RFC 7592: the bearer token that lets a client manage its own
      # registration. Hashed, never stored raw — same rule as every other
      # credential in this schema.
      add :registration_access_token_hash, :string

      # Whatever else the client asserted at registration. Kept whole so a
      # later question about what a client claimed can be answered without a
      # migration, and so nothing is silently dropped on the way in.
      add :metadata, :map, null: false, default: %{}

      # Null for a self-registered client — nobody has adopted it yet. Set once
      # a user consents, which is what ties a dynamically registered client to
      # an account.
      add :registered_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])
    create index(:oauth_clients, [:registered_by_id])
  end
end
