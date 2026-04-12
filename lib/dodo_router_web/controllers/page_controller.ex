defmodule DodoRouterWeb.PageController do
  use DodoRouterWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/routers")
  end
end
