defmodule DodoRouter.Routers.RoutingStep do
  use Ecto.Schema
  import Ecto.Changeset

  alias DodoRouter.Proxy.Adapter.Registry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @plan_types ~w(standard coding)

  # Canonical reasoning effort levels supported by the UI/proxy.
  # nil (unset) means "don't inject any reasoning control" — providers use
  # their own defaults or honor a client-supplied value instead.
  @reasoning_efforts ~w(none minimal low medium high xhigh max)

  schema "routing_steps" do
    field :position, :integer
    field :provider, :string
    field :model, :string
    field :plan_type, :string, default: "standard"
    field :temperature, :float
    field :max_tokens, :integer
    field :thinking_enabled, :boolean
    field :reasoning_effort, :string

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
      :reasoning_effort,
      :router_id,
      :provider_key_id
    ])
    |> validate_required([:provider, :model])
    |> validate_inclusion(:provider, Registry.providers())
    |> validate_inclusion(:plan_type, @plan_types)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_inclusion(:reasoning_effort, reasoning_efforts())
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

  def providers, do: Registry.providers()
  def plan_types, do: @plan_types
  def reasoning_efforts, do: @reasoning_efforts

  def available_models(provider), do: Registry.available_models(provider)
end
