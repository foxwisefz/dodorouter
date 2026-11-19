defmodule DodoRouterWeb.EndUserCaptureTest do
  use DodoRouterWeb.ConnCase, async: false

  alias DodoRouter.{AccountsFixtures, Logs, ProvidersFixtures, Routers, RoutersFixtures}

  setup do
    user = AccountsFixtures.user_fixture()
    {router, key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    {:ok, _} =
      Routers.create_routing_step(router, %{
        "provider" => "test_provider",
        "model" => "test-model",
        "provider_key_id" => provider_key.id
      })

    Logs.subscribe_to_logs(router.id)
    %{router: router, key: key}
  end

  test "sync and streaming requests across formats store the ID separately from headers", ctx do
    root = "/r/#{ctx.router.slug}/v1"
    chat = %{"model" => "test", "messages" => [%{"role" => "user", "content" => "Hi"}]}

    for {route, payload} <- [
          {root <> "/chat/completions", chat},
          {root <> "/messages", Map.put(chat, "max_tokens", 16)},
          {root <> "/responses", %{"model" => "test", "input" => "Hi"}},
          {"/v1/chat/completions", chat}
        ],
        stream <- [false, true] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.key}")
        |> put_req_header("x-dodo-user-id", "customer-42")
        |> put_req_header("x-session-id", "shared-session")
        |> post(route, Map.put(payload, "stream", stream))

      assert conn.status == 200
      assert_receive {:log_created, log}
      assert log.end_user_id == "customer-42"
      assert log.session_id == "shared-session"
      refute log.request_headers =~ "x-dodo-user-id"
      refute inspect(log.attempted_steps) =~ "customer-42"
    end
  end

  test "opaque tokens are stripped from logs and upstream headers and hashed per router", ctx do
    token = "sensitive-customer-credential"
    payload = %{"model" => "test", "messages" => [%{"role" => "user", "content" => "Hi"}]}
    {other, other_key} = RoutersFixtures.router_fixture()

    ids =
      for {router, key} <- [{ctx.router, ctx.key}, {ctx.router, ctx.key}, {other, other_key}] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{key}")
          |> put_req_header("x-dodo-user-token", token)
          |> post("/r/#{router.slug}/v1/chat/completions", payload)

        assert get_req_header(conn, "x-dodo-user-token") == []
        conn.assigns.end_user_id
      end

    assert [first, first, other_id] = ids
    assert first =~ ~r/^hmac:[0-9a-f]{64}$/
    assert other_id != first
    assert_receive {:log_created, log}
    assert log.end_user_id == first
    refute inspect(log) =~ token
    refute inspect(log) =~ "x-dodo-user-token"
  end

  test "rejects malformed or conflicting attribution before dispatch", ctx do
    for headers <- [
          [{"x-dodo-user-id", ""}],
          [{"x-dodo-user-token", " "}],
          [{"x-dodo-user-id", String.duplicate("a", 256)}],
          [{"x-dodo-user-id", "hmac:forged"}],
          [{"x-dodo-user-id", "bob"}, {"x-dodo-user-token", "sensitive"}],
          [{"x-dodo-user-id", "bob"}, {"x-dodo-user-id", "alice"}]
        ] do
      conn = put_req_header(build_conn(), "authorization", "Bearer #{ctx.key}")
      conn = %{conn | req_headers: headers ++ conn.req_headers}
      conn = post(conn, "/r/#{ctx.router.slug}/v1/chat/completions", %{})
      assert json_response(conn, 400)["error"]["type"] == "invalid_request_error"
      assert get_req_header(conn, "x-dodo-user-id") == []
      assert get_req_header(conn, "x-dodo-user-token") == []
    end

    refute_received {:log_created, _}
  end
end
