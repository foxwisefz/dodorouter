defmodule DodoRouterWeb.NavHooks do
  @moduledoc """
  LiveView hooks for navigation state.
  """

  import Phoenix.Component

  alias DodoRouter.Routers
  alias DodoRouter.Providers
  alias DodoRouter.Proxy.Adapter.Registry

  def on_mount(:load_routers, _params, _session, socket) do
    if socket.assigns[:current_user] do
      routers = Routers.list_routers(socket.assigns.current_user)
      {:cont, assign(socket, :nav_routers, routers)}
    else
      {:cont, assign(socket, :nav_routers, [])}
    end
  end

  def on_mount(:load_providers, _params, _session, socket) do
    if socket.assigns[:current_user] do
      provider_info = Registry.provider_info()

      nav_providers =
        socket.assigns.current_user
        |> Providers.list_provider_keys_grouped()
        |> Enum.map(fn {slug, keys} ->
          info = Map.get(provider_info, slug, %{name: slug, color: "base-content/50"})
          %{slug: slug, name: info.name, color: info.color, count: length(keys)}
        end)
        |> Enum.sort_by(& &1.name)

      {:cont, assign(socket, :nav_providers, nav_providers)}
    else
      {:cont, assign(socket, :nav_providers, [])}
    end
  end
end
