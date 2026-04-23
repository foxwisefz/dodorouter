defmodule DodoRouterWeb.TermsControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  describe "GET /terms" do
    test "renders terms page", %{conn: conn} do
      conn = get(conn, ~p"/terms")

      assert html_response(conn, 200) =~ "Terms"
    end
  end
end
