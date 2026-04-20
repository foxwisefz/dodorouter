defmodule DodoRouter.Logs.RequestLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(success fallback error)
  @call_types ~w(completion tool_call tool_enabled_completion)

  schema "request_logs" do
    field :request_id, Ecto.UUID
    field :status, :string
    field :http_status, :integer

    # Routing info
    field :attempted_steps, {:array, :map}, default: []
    field :final_provider, :string
    field :final_model, :string

    # Call type
    field :call_type, :string
    field :tools_invoked, {:array, :string}, default: []

    # Token usage
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :total_tokens, :integer

    # Timing
    field :latency_ms, :integer
    field :ttfb_ms, :integer

    # Request/response
    field :request_body, :string
    field :response_body, :string

    # Session grouping (Helicone-style)
    field :session_id, :string
    field :session_name, :string

    # Truncation metadata
    field :truncation_flags, {:array, :string}, default: []

    # Cost
    field :estimated_cost_usd, :decimal

    belongs_to :router, DodoRouter.Routers.Router

    field :inserted_at, :utc_datetime_usec
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :router_id,
      :request_id,
      :status,
      :http_status,
      :attempted_steps,
      :final_provider,
      :final_model,
      :call_type,
      :tools_invoked,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :latency_ms,
      :ttfb_ms,
      :request_body,
      :response_body,
      :estimated_cost_usd,
      :inserted_at,
      :session_id,
      :session_name,
      :truncation_flags
    ])
    |> validate_required([:router_id, :request_id, :status, :inserted_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:call_type, @call_types ++ [nil])
    |> validate_length(:session_id, max: 255)
    |> validate_length(:session_name, max: 255)
    |> foreign_key_constraint(:router_id)
    |> unique_constraint(:request_id)
  end

  def statuses, do: @statuses
  def call_types, do: @call_types
end
