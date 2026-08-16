defmodule DodoRouter.Logs.EvaluationRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "evaluation_runs" do
    field :status, :string, default: "pending"
    field :score, :integer
    field :max_score, :integer, default: 100
    # Deprecated: pass/fail was removed with judge prompt v2; no longer
    # written. Column kept for hot-upgrade safety — drop in a later deploy.
    field :passed, :boolean
    field :summary, :string
    field :criterion_scores, :map, default: %{}
    field :issues, {:array, :string}, default: []
    # The judge's step-by-step assessment, produced before the score.
    field :reasoning, :string
    # What the judge found missing/ambiguous in the rubric itself.
    field :rubric_gaps, {:array, :string}, default: []
    field :raw_judge_response, :string
    # Which source log this run measured. Nil means the evaluation's anchor
    # log — every run before multi-log evaluations existed.
    field :source_log_id, :binary_id
    # Which prompt variant this run measured; nil is the as-served baseline
    # (and every run from before variants existed). The patch itself lives
    # on the immutable evaluation, keyed by this name.
    field :variant_name, :string
    # What the provider's response claimed actually answered — nil when the
    # response named nothing or the row predates the column. The ranking is
    # keyed on candidate_model (what was requested); a difference here is a
    # provider-side alias/snapshot resolution the reader deserves to see.
    field :candidate_served_model, :string
    field :error, :string
    # Machine-readable twin of `error`: a stable token (rate_limited,
    # auth_error, provider_key_missing, empty_response, judge_unparseable,
    # judge_setup, crashed, cancelled, interrupted, ...) so clients decide
    # whether retrying could help without regexing prose. Nil on rows
    # written before the column existed.
    field :error_category, :string
    # "candidate" | "judge" — which half of the run failed. A judge failure
    # keeps candidate_output, so it can be re-judged without paying for the
    # answer twice. Nil unless status is "failed".
    field :failure_stage, :string
    # Set on the *copy* of an attempt that a retry replaced. A row with this
    # set is history: it is excluded from every aggregate, and reachable
    # only through the run that superseded it.
    field :superseded_at, :utc_datetime_usec
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

    # The judge key as it was when this run happened. The label is a
    # snapshot, so it survives the key being deleted — a run must keep
    # naming what judged it even after the evaluation is repointed at
    # another key. See Evaluations.judge_key_deleted?/1.
    field :judge_provider_key_label, :string
    # Same snapshot on the candidate side: candidate_provider names the
    # provider, never which of that provider's keys answered.
    field :candidate_provider_key_label, :string

    belongs_to :evaluation, DodoRouter.Logs.Evaluation
    belongs_to :judge_log, DodoRouter.Logs.RequestLog
    belongs_to :candidate_log, DodoRouter.Logs.RequestLog
    belongs_to :candidate_provider_key, DodoRouter.Providers.ProviderKey
    belongs_to :judge_provider_key, DodoRouter.Providers.ProviderKey
    belongs_to :superseded_by, __MODULE__

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :score,
      :max_score,
      :summary,
      :criterion_scores,
      :issues,
      :reasoning,
      :rubric_gaps,
      :raw_judge_response,
      :source_log_id,
      :variant_name,
      :candidate_served_model,
      :error,
      :error_category,
      :failure_stage,
      :superseded_at,
      :superseded_by_id,
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
      :judge_log_id,
      :judge_provider_key_id,
      :judge_provider_key_label,
      :candidate_provider_key_label
    ])
    |> validate_required([:status, :evaluation_id, :judge_prompt_version])
    |> validate_inclusion(:status, ~w(pending running completed failed))
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:evaluation_id)
  end
end
