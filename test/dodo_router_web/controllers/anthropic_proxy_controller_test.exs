defmodule DodoRouterWeb.AnthropicProxyControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.RoutersFixtures

  setup do
    {router, api_key} = RoutersFixtures.router_fixture()
    %{router: router, api_key: api_key}
  end

  defp auth_conn(conn, api_key) do
    put_req_header(conn, "x-api-key", api_key)
  end

  describe "POST /r/:router_slug/v1/messages" do
    test "returns error when no routing configured", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages", %{
          "model" => "claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 1024
        })

      assert %{
               "type" => "error",
               "error" => %{
                 "type" => "invalid_request_error"
               }
             } = json_response(conn, 400)
    end

    test "returns 401 without auth", %{conn: conn, router: router} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages", %{})

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "accepts x-api-key header for auth", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> put_req_header("x-api-key", api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages", %{
          "model" => "claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 1024
        })

      assert conn.status != 401
    end

    test "also accepts Bearer token auth", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages", %{
          "model" => "claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "max_tokens" => 1024
        })

      assert conn.status != 401
    end
  end
end
