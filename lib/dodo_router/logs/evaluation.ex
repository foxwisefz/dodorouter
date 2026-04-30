defmodule DodoRouter.Logs.Evaluation do
  @moduledoc """
  Schema for storing evaluations of request logs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "evaluations" do
    field :status, :string, default: "pending"
    field :rating_type, :string, default: "good"
    field :rating_explanation, :string
    field :score, :integer, default: 0
    field :max_score, :integer, default: 100
    field :category, :string

    belongs_to :request_log, DodoRouter.Logs.RequestLog
    belongs_to :evaluated_by, DodoRouter.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for an evaluation.
  """
  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, [
      :status,
      :rating_type,
      :rating_explanation,
      :score,
      :max_score,
      :category,
      :request_log_id,
      :evaluated_by_id
    ])
    |> validate_required([:request_log_id, :evaluated_by_id])
    |> validate_number(:score, greater_than_or_equal_to: 0)
    |> validate_number(:max_score, greater_than: 0)
    |> validate_inclusion(:status, ["pending", "approved", "rejected", "in_progress"])
    |> validate_inclusion(:rating_type, ["good", "bad"])
    |> foreign_key_constraint(:request_log_id)
    |> foreign_key_constraint(:evaluated_by_id)
  end
end
