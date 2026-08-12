defmodule DodoRouter.Repo.Migrations.CreateAgentApiCalls do
  use Ecto.Migration

  # What an agent did, tried, and was refused, on the agent surface.
  #
  # The gap this closes: a credential that can read every prompt a product
  # ever sent, with no record that anyone used it. "Nothing looks wrong" and
  # "we have no way to tell" are indistinguishable without this table.
  #
  # Deliberately credential-agnostic. `principal_kind` plus a nullable
  # `agent_token_id` means an OAuth access token can be recorded here later
  # without a migration, which matters because the credential decision
  # (dodo_router-5m5.5) is intentionally the last one made.
  def change do
    create table(:agent_api_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Denormalised, and nilify rather than cascade: an audit row must
      # outlive the credential it describes. Revoking a token after a leak is
      # exactly when its history becomes worth reading, so deleting the token
      # must not delete the evidence.
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :agent_token_id,
          references(:agent_tokens, type: :binary_id, on_delete: :nilify_all)

      add :router_id, references(:routers, type: :binary_id, on_delete: :nilify_all)

      # "agent_token" today; "oauth" once an authorization server exists.
      add :principal_kind, :string, null: false
      # Token name at the time of the call, or the MCP client's own clientInfo
      # name. Copied rather than joined so the row still reads after a rename.
      add :principal_name, :string

      # "rest" or "mcp" — the same operation is reachable both ways, and
      # which door was used is part of the story.
      add :interface, :string, null: false
      # "GET /logs" or the JSON-RPC method; `tool` carries the MCP tool name.
      add :operation, :string, null: false
      add :tool, :string

      # Scopes the principal actually held, so a later scope change doesn't
      # rewrite what this call was permitted to do at the time.
      add :scopes, {:array, :string}, null: false, default: []

      # What was touched. Kept as type+id rather than a real association
      # because it spans logs and evaluations.
      add :target_type, :string
      add :target_id, :binary_id

      # "ok", "denied" or "error". A denied attempt is the most interesting
      # row in the table and must be recorded as loudly as a successful one.
      add :outcome, :string, null: false
      add :http_status, :integer
      add :error, :text

      # Whether the response actually carried prompt/response text, which is
      # the read worth being able to find again later.
      add :returned_bodies, :boolean, null: false, default: false

      add :remote_ip, :string
      add :user_agent, :string
      add :duration_ms, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:agent_api_calls, [:user_id, :inserted_at])
    create index(:agent_api_calls, [:agent_token_id, :inserted_at])
    create index(:agent_api_calls, [:router_id, :inserted_at])
    # Denied and body-carrying reads are what an operator scans for first.
    create index(:agent_api_calls, [:outcome, :inserted_at])
  end
end
