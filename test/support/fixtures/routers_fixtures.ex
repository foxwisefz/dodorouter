defmodule DodoRouter.RoutersFixtures do
  @moduledoc """
  Test helpers for creating router entities.
  """

  alias DodoRouter.Routers
  alias DodoRouter.AccountsFixtures

  def unique_router_slug, do: "router-#{System.unique_integer([:positive])}"
  def unique_router_name, do: "Router #{System.unique_integer([:positive])}"

  def valid_router_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_router_name(),
      slug: unique_router_slug()
    })
  end

  def router_fixture(user \\ nil, attrs \\ %{}) do
    user = user || AccountsFixtures.user_fixture()

    {:ok, router, api_key} =
      attrs
      |> valid_router_attributes()
      |> then(&Routers.create_router(user, &1))

    {router, api_key}
  end

  def router_with_api_key(user \\ nil, attrs \\ %{}) do
    router_fixture(user, attrs)
  end
end
