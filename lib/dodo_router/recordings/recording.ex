defmodule DodoRouter.Recordings.Recording do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(recording stopped)

  schema "recordings" do
    field :name, :string
    field :status, :string, default: "recording"
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec

    belongs_to :router, DodoRouter.Routers.Router

    timestamps()
  end

  def changeset(recording, attrs) do
    recording
    |> cast(attrs, [:name, :status, :started_at, :stopped_at, :router_id])
    |> validate_required([:status, :started_at, :router_id])
    |> validate_length(:name, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:router_id)
  end

  def start_changeset(recording, attrs) do
    attrs = Map.put_new(attrs, :started_at, DateTime.utc_now())

    recording
    |> changeset(attrs)
    |> put_change(:status, "recording")
  end

  def stop_changeset(recording) do
    recording
    |> change(%{status: "stopped", stopped_at: DateTime.utc_now()})
  end

  def statuses, do: @statuses
end
