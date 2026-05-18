defmodule DodoRouterWeb.ProxyControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.RoutersFixtures

  setup do
    {router, api_key} = RoutersFixtures.router_fixture()
    %{router: router, api_key: api_key}
  end

  defp auth_conn(conn, api_key) do
    put_req_header(conn, "authorization", "Bearer #{api_key}")
  end

  describe "GET /r/:router_slug/v1/models" do
    test "returns models list", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> auth_conn(api_key)
        |> get("/r/#{router.slug}/v1/models")

      assert %{
               "object" => "list",
               "data" => [
                 %{
                   "id" => id,
                   "object" => "model",
                   "owned_by" => "dodo"
                 }
               ]
             } = json_response(conn, 200)

      assert id == router.slug
    end

    test "returns 401 without auth", %{conn: conn, router: router} do
      conn = get(conn, "/r/#{router.slug}/v1/models")

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "returns 401 with invalid api key", %{conn: conn, router: router} do
      conn =
        conn
        |> auth_conn("sk-dodo-invalid")
        |> get("/r/#{router.slug}/v1/models")

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end
  end

  describe "POST /r/:router_slug/v1/chat/completions" do
    test "returns error when no routing configured", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/chat/completions", %{
          "model" => "test",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{
               "error" => %{
                 "type" => "invalid_request_error"
               }
             } = json_response(conn, 400)
    end

    test "returns 401 without auth", %{conn: conn, router: router} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/chat/completions", %{})

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end
  end

  describe "POST /v1/chat/completions (legacy)" do
    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{})

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "returns error when no routing configured", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{
          "model" => "test",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert %{"error" => %{"type" => "invalid_request_error"}} = json_response(conn, 400)
    end
  end
end
