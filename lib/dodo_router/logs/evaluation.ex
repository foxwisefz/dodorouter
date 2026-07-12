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
    field :repetitions, :integer, default: 3
    field :benchmark_status, :string, default: "draft"
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
    |> foreign_key_constraint(:request_log_id)
    |> foreign_key_constraint(:evaluated_by_id)
    |> foreign_key_constraint(:judge_provider_key_id)
  end
end
