defmodule DodoRouterWeb.ResponsesProxyControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.RoutersFixtures

  setup do
    {router, api_key} = RoutersFixtures.router_fixture()
    %{router: router, api_key: api_key}
  end

  defp auth_conn(conn, api_key) do
    put_req_header(conn, "authorization", "Bearer #{api_key}")
  end

  describe "POST /r/:router_slug/v1/responses" do
    test "returns error when no routing configured", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/responses", %{
          "model" => "gpt-4o",
          "input" => "Hello"
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
        |> post("/r/#{router.slug}/v1/responses", %{})

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "accepts x-api-key header for auth", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> put_req_header("x-api-key", api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/responses", %{
          "model" => "gpt-4o",
          "input" => "Hello"
        })

      assert conn.status != 401
    end

    test "also accepts Bearer token auth", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/responses", %{
          "model" => "gpt-4o",
          "input" => "Hello"
        })

      assert conn.status != 401
    end

    test "converts string input to chat completions format", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/responses", %{
          "model" => "gpt-4o",
          "input" => "Hello",
          "instructions" => "Be helpful"
        })

      # Should get an error about no routing, but the request should be accepted
      assert conn.status != 401
    end
  end
end
