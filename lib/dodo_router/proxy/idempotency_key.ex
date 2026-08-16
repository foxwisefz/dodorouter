defmodule DodoRouter.Proxy.IdempotencyKey do
  @moduledoc """
  One reserved Idempotency-Key on one router.

  The `(router_id, key)` unique index is the concurrency guarantee: of two
  racing requests carrying the same key, exactly one inserts this row and
  calls upstream. Written programmatically by `DodoRouter.Proxy.Idempotency`
  — there is deliberately no changeset taking client params.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "idempotency_keys" do
    field :key, :string
    field :request_hash, :binary
    field :request_id, :binary_id
    field :status, :string, default: "in_progress"

    belongs_to :router, DodoRouter.Routers.Router

    timestamps(type: :utc_datetime_usec)
  end
end
