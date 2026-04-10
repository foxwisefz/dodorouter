defmodule DodoRouter.Projects.RoutingStep do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(zai moonshot)
  @plan_types ~w(standard coding)

  schema "routing_steps" do
    field :position, :integer
    field :provider, :string
    field :model, :string
    field :plan_type, :string, default: "standard"
    field :temperature, :float
    field :max_tokens, :integer
    field :thinking_enabled, :boolean

    belongs_to :project, DodoRouter.Projects.Project

    timestamps()
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:position, :provider, :model, :plan_type, :temperature, :max_tokens, :thinking_enabled, :project_id])
    |> validate_required([:provider, :model])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:plan_type, @plan_types)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :position])
  end

  def create_changeset(step, attrs, project_id, position) do
    step
    |> changeset(attrs)
    |> put_change(:project_id, project_id)
    |> put_change(:position, position)
    |> validate_required([:position, :project_id])
  end

  def providers, do: @providers
  def plan_types, do: @plan_types

  def available_models("zai"), do: ~w(glm-5.1 glm-5 glm-5-turbo glm-4.7 glm-4.6 glm-4.5)
  def available_models("moonshot"), do: ~w(kimi-k2.5 kimi-k2 moonshot-v1-8k moonshot-v1-32k moonshot-v1-128k)
  def available_models(_), do: []
end
