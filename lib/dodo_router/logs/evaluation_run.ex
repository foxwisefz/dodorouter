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
    field :judge_cost_usd, :decimal
    # API list-price counterparts of the two cost fields, copied from the
    # linked logs so plan-based ($0) runs stay cost-comparable.
    field :candidate_list_cost_usd, :decimal
    field :judge_list_cost_usd, :decimal
    # Groups the runs of one benchmark execution; re-runs get a fresh batch
    # so aggregates don't mix executions. Nil on rows from before batching.
    field :batch_id, :binary_id

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
      :judge_cost_usd,
      :candidate_list_cost_usd,
      :judge_list_cost_usd,
      :batch_id,
      :evaluation_id,
      :judge_log_id
    ])
    |> validate_required([:status, :evaluation_id, :judge_prompt_version])
    |> validate_inclusion(:status, ~w(pending running completed failed))
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:evaluation_id)
  end
end
