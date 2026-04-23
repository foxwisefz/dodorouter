defmodule DodoRouterWeb.HealthControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns ok when database is available", %{conn: conn} do
      conn = get(conn, "/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end
end
