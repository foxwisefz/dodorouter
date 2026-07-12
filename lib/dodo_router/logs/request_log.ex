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
    field :traffic_type, :string, default: "proxy"

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
    field :cache_read_tokens, :integer
    field :cache_write_tokens, :integer

    # Timing
    field :latency_ms, :integer
    field :ttfb_ms, :integer
    field :upload_ms, :integer
    field :provider_processing_ms, :integer

    # Payload
    field :payload_size_bytes, :integer

    # Request/response
    field :request_body, :string
    field :response_body, :string
    field :request_headers, :string
    field :response_headers, :string

    # Session grouping (Helicone-style)
    field :session_id, :string
    field :session_name, :string

    # Recording (server-side capture)
    field :recording_id, :binary_id

    # Truncation metadata
    field :truncation_flags, {:array, :string}, default: []

    # Favorited for later review/benchmarking
    field :favorite, :boolean, default: false

    # Cost
    field :estimated_cost_usd, :decimal

    belongs_to :router, DodoRouter.Routers.Router

    # Replay linkage: set when this log was produced by re-running another log
    belongs_to :replayed_from, __MODULE__
    has_many :replays, __MODULE__, foreign_key: :replayed_from_id
    has_many :evaluations, DodoRouter.Logs.Evaluation

    # Message index the replay was anchored at (nil = whole thread). Stored
    # explicitly: an anchor at the last user message doesn't shorten the
    # history, so it can't be derived from the message prefix.
    field :replay_from_index, :integer

    field :inserted_at, :utc_datetime_usec
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :router_id,
      :request_id,
      :status,
      :http_status,
      :traffic_type,
      :attempted_steps,
      :final_provider,
      :final_model,
      :call_type,
      :tools_invoked,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :latency_ms,
      :ttfb_ms,
      :upload_ms,
      :provider_processing_ms,
      :payload_size_bytes,
      :request_body,
      :response_body,
      :request_headers,
      :response_headers,
      :estimated_cost_usd,
      :inserted_at,
      :session_id,
      :session_name,
      :recording_id,
      :truncation_flags,
      :favorite,
      :replayed_from_id,
      :replay_from_index
    ])
    |> validate_required([:router_id, :request_id, :status, :inserted_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:call_type, @call_types ++ [nil])
    |> validate_length(:session_id, max: 255)
    |> validate_length(:session_name, max: 255)
    |> foreign_key_constraint(:router_id)
    |> foreign_key_constraint(:replayed_from_id)
    |> unique_constraint(:request_id)
  end

  def statuses, do: @statuses
  def call_types, do: @call_types
end
