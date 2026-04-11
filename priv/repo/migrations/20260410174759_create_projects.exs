defmodule DodoRouter.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :api_key_hash, :string, null: false
      add :api_key_prefix, :string, null: false

      timestamps()
    end

    create unique_index(:projects, [:slug])
    create unique_index(:projects, [:api_key_hash])

    create table(:routing_steps, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :plan_type, :string, default: "standard"
      add :temperature, :float
      add :max_tokens, :integer
      add :thinking_enabled, :boolean

      timestamps()
    end

    create index(:routing_steps, [:project_id])
    create unique_index(:routing_steps, [:project_id, :position])

    create table(:request_logs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false
      add :request_id, :uuid, null: false
      add :status, :string, null: false
      add :http_status, :integer

      # Routing info
      add :attempted_steps, :jsonb, null: false, default: "[]"
      add :final_provider, :string
      add :final_model, :string

      # Call type tracking
      add :call_type, :string
      add :tools_invoked, :jsonb, default: "[]"

      # Token usage
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :total_tokens, :integer

      # Timing
      add :latency_ms, :integer
      add :ttfb_ms, :integer

      # Request/response (optional)
      add :request_body, :text
      add :response_body, :text

      # Cost
      add :estimated_cost_usd, :numeric, precision: 12, scale: 8

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:request_logs, [:project_id, :inserted_at])
    create index(:request_logs, [:project_id, :final_model])
    create index(:request_logs, [:inserted_at])
    create unique_index(:request_logs, [:request_id])

    create table(:model_pricing, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider, :string, null: false
      add :model, :string, null: false
      add :input_cost_per_1m_tokens, :numeric, precision: 10, scale: 6
      add :output_cost_per_1m_tokens, :numeric, precision: 10, scale: 6
      add :context_window, :integer
      add :supports_streaming, :boolean, default: true
      add :is_active, :boolean, default: true

      timestamps()
    end

    create unique_index(:model_pricing, [:provider, :model])
  end
end
