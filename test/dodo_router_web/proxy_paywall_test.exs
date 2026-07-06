defmodule DodoRouterWeb.ProxyPaywallTest do
  use DodoRouterWeb.ConnCase, async: true

  import DodoRouter.AccountsFixtures

  alias DodoRouter.RoutersFixtures

  setup do
    user = unsubscribed_user_fixture()
    {router, api_key} = RoutersFixtures.router_fixture(user)
    %{user: user, router: router, api_key: api_key}
  end

  defp auth_conn(conn, api_key) do
    put_req_header(conn, "authorization", "Bearer #{api_key}")
  end

  test "unpaid owner gets 402 on chat completions", %{
    conn: conn,
    router: router,
    api_key: api_key
  } do
    conn =
      conn
      |> auth_conn(api_key)
      |> post("/r/#{router.slug}/v1/chat/completions", %{
        "model" => "anything",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert %{"error" => error} = json_response(conn, 402)
    assert error["type"] == "billing_error"
    assert error["code"] == "payment_required"
  end

  test "unpaid owner gets 402 on the anthropic endpoint", %{
    conn: conn,
    router: router,
    api_key: api_key
  } do
    conn =
      conn
      |> auth_conn(api_key)
      |> post("/r/#{router.slug}/v1/messages", %{
        "model" => "anything",
        "max_tokens" => 16,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert json_response(conn, 402)["error"]["type"] == "billing_error"
  end

  test "unpaid owner gets 402 on models list", %{conn: conn, router: router, api_key: api_key} do
    conn =
      conn
      |> auth_conn(api_key)
      |> get("/r/#{router.slug}/v1/models")

    assert json_response(conn, 402)["error"]["type"] == "billing_error"
  end

  test "subscribing restores access", %{conn: conn, user: user, router: router, api_key: api_key} do
    set_subscription_status(user, "active")

    conn =
      conn
      |> auth_conn(api_key)
      |> get("/r/#{router.slug}/v1/models")

    assert json_response(conn, 200)
  end

  test "invalid key still returns 401, not 402", %{conn: conn, router: router} do
    conn =
      conn
      |> auth_conn("sk-dodo-invalid")
      |> get("/r/#{router.slug}/v1/models")

    assert json_response(conn, 401)["error"]["type"] == "authentication_error"
  end
end
