defmodule DodoRouterWeb.TermsController do
  use DodoRouterWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
