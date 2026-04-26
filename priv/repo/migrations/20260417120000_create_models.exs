defmodule DodoRouter.Repo.Migrations.CreateModels do
  use Ecto.Migration

  def change do
    create table(:models, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_slug, :string, null: false
      add :model_id, :string, null: false
      add :display_name, :string, null: false

      # Token limits
      add :max_input_tokens, :integer
      add :max_output_tokens, :integer

      # Pricing (per 1M tokens, stored as decimal for precision)
      add :input_price_per_million, :decimal, precision: 12, scale: 4
      add :output_price_per_million, :decimal, precision: 12, scale: 4
      add :price_effective_at, :utc_datetime

      # Capabilities
      add :supports_vision, :boolean, default: false
      add :supports_audio_input, :boolean, default: false
      add :supports_audio_output, :boolean, default: false
      add :supports_function_calling, :boolean, default: false
      add :supports_streaming, :boolean, default: true
      add :supports_system_messages, :boolean, default: true
      add :supports_response_schema, :boolean, default: false
      add :supports_reasoning, :boolean, default: false
      add :supports_prompt_caching, :boolean, default: false

      # Metadata
      add :deprecation_date, :date
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:models, [:provider_slug, :model_id])
    create index(:models, [:provider_slug])
  end
end
