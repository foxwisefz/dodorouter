defmodule DodoRouter.Models.Model do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "models" do
    field :provider_slug, :string
    field :model_id, :string
    field :display_name, :string

    # Token limits
    field :max_input_tokens, :integer
    field :max_output_tokens, :integer

    # Pricing (per 1M tokens)
    field :input_price_per_million, :decimal
    field :output_price_per_million, :decimal
    field :cache_read_price_per_million, :decimal
    field :cache_write_price_per_million, :decimal
    field :price_effective_at, :utc_datetime

    # Capabilities
    field :supports_vision, :boolean, default: false
    field :supports_audio_input, :boolean, default: false
    field :supports_audio_output, :boolean, default: false
    field :supports_function_calling, :boolean, default: false
    field :supports_streaming, :boolean, default: true
    field :supports_system_messages, :boolean, default: true
    field :supports_response_schema, :boolean, default: false
    field :supports_reasoning, :boolean, default: false
    field :supports_prompt_caching, :boolean, default: false

    # Metadata
    field :deprecation_date, :date
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [:provider_slug, :model_id, :display_name]
  @optional_fields [
    :max_input_tokens,
    :max_output_tokens,
    :input_price_per_million,
    :output_price_per_million,
    :cache_read_price_per_million,
    :cache_write_price_per_million,
    :price_effective_at,
    :supports_vision,
    :supports_audio_input,
    :supports_audio_output,
    :supports_function_calling,
    :supports_streaming,
    :supports_system_messages,
    :supports_response_schema,
    :supports_reasoning,
    :supports_prompt_caching,
    :deprecation_date,
    :metadata
  ]

  def changeset(model, attrs) do
    model
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:provider_slug, :model_id])
  end

  def full_model_id(%__MODULE__{provider_slug: provider, model_id: model_id}) do
    "#{provider}/#{model_id}"
  end
end
