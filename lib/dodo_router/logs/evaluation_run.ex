defmodule DodoRouter.Logs.EvaluationRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "evaluation_runs" do
    field :status, :string, default: "pending"
    field :score, :integer
    field :max_score, :integer, default: 100
    field :passed, :boolean
    field :summary, :string
    field :criterion_scores, :map, default: %{}
    field :issues, {:array, :string}, default: []
    field :raw_judge_response, :string
    field :error, :string
    field :duration_ms, :integer
    field :judge_prompt_version, :string, default: "v1"
    field :candidate_provider, :string
    field :candidate_model, :string
    field :repetition, :integer
    field :candidate_latency_ms, :integer
    field :candidate_cost_usd, :decimal
    field :candidate_output, :string

    belongs_to :evaluation, DodoRouter.Logs.Evaluation
    belongs_to :judge_log, DodoRouter.Logs.RequestLog
    belongs_to :candidate_log, DodoRouter.Logs.RequestLog
    belongs_to :candidate_provider_key, DodoRouter.Providers.ProviderKey

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :score,
      :max_score,
      :passed,
      :summary,
      :criterion_scores,
      :issues,
      :raw_judge_response,
      :error,
      :duration_ms,
      :judge_prompt_version,
      :candidate_provider_key_id,
      :candidate_provider,
      :candidate_model,
      :repetition,
      :candidate_log_id,
      :candidate_latency_ms,
      :candidate_cost_usd,
      :candidate_output,
      :evaluation_id,
      :judge_log_id
    ])
    |> validate_required([:status, :evaluation_id, :judge_prompt_version])
    |> validate_inclusion(:status, ~w(pending running completed failed))
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:evaluation_id)
  end
end
