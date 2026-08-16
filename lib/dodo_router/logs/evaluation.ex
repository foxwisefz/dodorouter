defmodule DodoRouter.Logs.Evaluation do
  @moduledoc """
  Schema for storing evaluations of request logs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "evaluations" do
    field :name, :string
    field :criteria, :string
    field :good_examples, :string
    field :bad_examples, :string
    field :judge_model, :string
    field :candidate_targets, {:array, :map}, default: []
    # The set of source logs a multi-log evaluation replays; empty means
    # just the anchor. request_log_id stays required as the anchor
    # (= first of the set), so every router-scoping join keeps working.
    field :source_log_ids, {:array, :binary_id}, default: []
    field :repetitions, :integer, default: 3
    field :benchmark_status, :string, default: "draft"
    # Batch written by the most recent benchmark execution; aggregates are
    # scoped to it. Set programmatically, never cast from params.
    field :last_batch_id, :binary_id
    field :run_count, :integer, virtual: true, default: 0
    # Compatibility with databases created from the earlier unused schema.
    field :rating_type, :string, default: "good"

    belongs_to :request_log, DodoRouter.Logs.RequestLog
    belongs_to :evaluated_by, DodoRouter.Accounts.User
    belongs_to :judge_provider_key, DodoRouter.Providers.ProviderKey
    has_many :runs, DodoRouter.Logs.EvaluationRun

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for an evaluation.
  """
  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, [
      :name,
      :criteria,
      :good_examples,
      :bad_examples,
      :judge_model,
      :candidate_targets,
      :source_log_ids,
      :repetitions,
      :judge_provider_key_id,
      :request_log_id,
      :evaluated_by_id
    ])
    |> validate_required([
      :name,
      :criteria,
      :judge_model,
      :judge_provider_key_id,
      :request_log_id,
      :evaluated_by_id
    ])
    |> validate_length(:name, max: 120)
    |> validate_length(:criteria, max: 10_000)
    |> validate_number(:repetitions, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_length(:candidate_targets, min: 1, max: 30)
    |> validate_length(:source_log_ids, max: 20)
    |> validate_candidate_target_shape()
    |> foreign_key_constraint(:request_log_id)
    |> foreign_key_constraint(:evaluated_by_id)
    |> foreign_key_constraint(:judge_provider_key_id)
  end

  @doc """
  The full set of source logs this evaluation replays. Rows from before
  multi-log evaluations (or created single-log) read as just the anchor.
  """
  def source_log_ids(%__MODULE__{source_log_ids: ids, request_log_id: anchor}) do
    case ids do
      ids when is_list(ids) and ids != [] -> ids
      _ -> [anchor]
    end
  end

  defp validate_candidate_target_shape(changeset) do
    validate_change(changeset, :candidate_targets, fn :candidate_targets, targets ->
      valid? =
        Enum.all?(targets, fn
          %{} = target ->
            Enum.all?(
              ~w(provider_key_id provider model),
              &(is_binary(target[&1]) and target[&1] != "")
            )

          _other ->
            false
        end)

      if valid?,
        do: [],
        else: [candidate_targets: "entries must include provider_key_id, provider, and model"]
    end)
  end
end
