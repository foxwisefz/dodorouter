defmodule DodoRouter.Routers.RoutingChangeEvent do
  @moduledoc """
  One applied (or reverted) routing change, with the evidence that
  justified it.

  `before_step` / `after_step` snapshot the step fields the change touched
  — provider, provider key (id and label), model, plan_type — so the row
  stays readable after the key, the step, or the evaluation is gone.
  Everything here is written programmatically from resolved structs; there
  is deliberately no cast/changeset taking client params.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "routing_change_events" do
    field :routing_step_id, :binary_id
    field :evaluation_id, :binary_id
    field :batch_id, :binary_id
    field :changed_by_id, :binary_id
    field :before_step, :map
    field :after_step, :map
    field :reverted_at, :utc_datetime_usec

    belongs_to :router, DodoRouter.Routers.Router

    timestamps(type: :utc_datetime)
  end
end
