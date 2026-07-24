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

    test "accepts request bodies larger than Plug's 8MB default (base64 images)", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      # Claude Code sends screenshots as base64 image blocks; a session with a
      # few of them easily exceeds Plug.Parsers' 8MB default and used to 413.
      big_image = String.duplicate("A", 9_000_000)

      body =
        Jason.encode!(%{
          "model" => "claude-sonnet-4-20250514",
          "max_tokens" => 1024,
          "messages" => [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "text", "text" => "what is in this image?"},
                %{
                  "type" => "image",
                  "source" => %{
                    "type" => "base64",
                    "media_type" => "image/png",
                    "data" => big_image
                  }
                }
              ]
            }
          ]
        })

      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages", body)

      # No routing configured, so the request should reach the controller and
      # get its normal 400 — not be rejected at the parser with 413.
      assert json_response(conn, 400)["error"]["type"] == "invalid_request_error"
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

  describe "POST /r/:router_slug/v1/messages/count_tokens" do
    test "returns 401 without auth", %{conn: conn, router: router} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages/count_tokens", %{
          "model" => "claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => "Hello"}]
        })

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "returns a heuristic estimate when no Anthropic step is configured", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn =
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages/count_tokens", %{
          "model" => "claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => "Hello, how are you today?"}]
        })

      assert %{"input_tokens" => tokens} = json_response(conn, 200)
      assert is_integer(tokens) and tokens > 0
    end

    test "estimate grows with input size", %{conn: conn, router: router, api_key: api_key} do
      count = fn content ->
        conn
        |> auth_conn(api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/r/#{router.slug}/v1/messages/count_tokens", %{
          "model" => "claude-sonnet-4-20250514",
          "messages" => [%{"role" => "user", "content" => content}]
        })
        |> json_response(200)
        |> Map.fetch!("input_tokens")
      end

      small = count.("Hello")
      large = count.(String.duplicate("Hello world, this is a longer message. ", 200))
      assert large > small
    end
  end
end
