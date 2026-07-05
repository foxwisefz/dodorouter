defmodule DodoRouterWeb.PageController do
  use DodoRouterWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/routers")
    else
      # Send visitors straight to login without the "you must log in"
      # error flash they'd get from bouncing off an authenticated route.
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
