defmodule DodoRouterWeb.NavHooks do
  @moduledoc """
  LiveView hooks for navigation state.
  """

  import Phoenix.Component

  alias DodoRouter.Routers
  alias DodoRouter.Providers

  def on_mount(:load_routers, _params, _session, socket) do
    if socket.assigns[:current_user] do
      routers = Routers.list_routers_with_step_count(socket.assigns.current_user)
      {:cont, assign(socket, :nav_routers, routers)}
    else
      {:cont, assign(socket, :nav_routers, [])}
    end
  end

  def on_mount(:load_providers, _params, _session, socket) do
    if socket.assigns[:current_user] do
      provider_count =
        socket.assigns.current_user
        |> Providers.list_provider_keys()
        |> length()

      {:cont, assign(socket, :nav_provider_count, provider_count)}
    else
      {:cont, assign(socket, :nav_provider_count, 0)}
    end
  end
end
