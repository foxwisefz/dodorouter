defmodule DodoRouterWeb.NavHooks do
  @moduledoc """
  LiveView hooks for navigation state.
  """

  import Phoenix.Component

  alias DodoRouter.Routers

  def on_mount(:load_routers, _params, _session, socket) do
    if socket.assigns[:current_user] do
      routers = Routers.list_routers(socket.assigns.current_user)
      {:cont, assign(socket, :nav_routers, routers)}
    else
      {:cont, assign(socket, :nav_routers, [])}
    end
  end
end
