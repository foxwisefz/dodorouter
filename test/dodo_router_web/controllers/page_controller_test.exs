defmodule DodoRouterWeb.PageControllerTest do
  use DodoRouterWeb.ConnCase

  test "GET / redirects logged-in users to /routers", %{conn: conn} do
    conn = conn |> log_in_user(DodoRouter.AccountsFixtures.user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/routers"
  end

  test "GET / sends visitors to the login page without an error flash", %{conn: conn} do
    conn = get(conn, ~p"/")

    # A first visit to the app root is not a mistake — no scary red flash.
    assert redirected_to(conn) == ~p"/users/log-in"
    refute Phoenix.Flash.get(conn.assigns.flash, :error)
  end
end
