defmodule DodoRouterWeb.PageController do
  use DodoRouterWeb, :controller

  def home(conn, _params) do
    if scope = conn.assigns[:current_scope] do
      # A user with no routers yet goes straight into creating one
      if DodoRouter.Routers.list_routers(scope.user) == [] do
        redirect(conn, to: ~p"/routers/new")
      else
        redirect(conn, to: ~p"/routers")
      end
    else
      # Send visitors straight to login without the "you must log in"
      # error flash they'd get from bouncing off an authenticated route.
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
