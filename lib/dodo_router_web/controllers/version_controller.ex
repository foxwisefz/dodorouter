defmodule DodoRouterWeb.VersionController do
  use DodoRouterWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      version: Application.spec(:dodo_router, :vsn) |> to_string()
    })
  end
end
