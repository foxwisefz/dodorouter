defmodule DodoRouter.Logs.EvalMonitor do
  @moduledoc """
  Keeps a shipped downgrade honest: after a verdict is applied, the same
  rubric and judge keep scoring what production actually serves, and a
  sustained drop below the accepted baseline raises an anomaly.

  One monitor per evaluation. All fields are written programmatically from
  resolved structs — the baseline comes from the accepted benchmark's own
  ranking, never from client params.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "eval_monitors" do
    field :evaluation_id, :binary_id
    field :change_event_id, :binary_id
    field :status, :string, default: "active"
    field :baseline_avg, :integer
    field :baseline_stddev, :integer
    field :target_model, :string
    field :sample_size, :integer, default: 3
    field :interval_hours, :integer, default: 24
    field :last_sampled_at, :utc_datetime_usec
    field :consecutive_drops, :integer, default: 0
    field :alerted_at, :utc_datetime_usec

    belongs_to :router, DodoRouter.Routers.Router

    timestamps(type: :utc_datetime)
  end
end
