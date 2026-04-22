defmodule DodoRouterWeb.PageControllerTest do
  use DodoRouterWeb.ConnCase

  test "GET / redirects to /routers", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/routers"
  end
end
