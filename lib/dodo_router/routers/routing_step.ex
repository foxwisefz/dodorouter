defmodule DodoRouter.Routers.RoutingStep do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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

    belongs_to :router, DodoRouter.Routers.Router
    belongs_to :provider_key, DodoRouter.Providers.ProviderKey

    timestamps()
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :position,
      :provider,
      :model,
      :plan_type,
      :temperature,
      :max_tokens,
      :thinking_enabled,
      :router_id,
      :provider_key_id
    ])
    |> validate_required([:provider, :model])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:plan_type, @plan_types)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> foreign_key_constraint(:router_id)
    |> foreign_key_constraint(:provider_key_id)
    |> unique_constraint([:router_id, :position])
  end

  def create_changeset(step, attrs, router_id, position) do
    step
    |> changeset(attrs)
    |> put_change(:router_id, router_id)
    |> put_change(:position, position)
    |> validate_required([:position, :router_id])
  end

  def providers, do: @providers
  def plan_types, do: @plan_types

  def available_models("zai"), do: ~w(glm-5.1 glm-5 glm-5-turbo glm-4.7 glm-4.6 glm-4.5)

  def available_models("moonshot"),
    do: ~w(kimi-k2.5 kimi-k2 moonshot-v1-8k moonshot-v1-32k moonshot-v1-128k)

  def available_models(_), do: []
end
