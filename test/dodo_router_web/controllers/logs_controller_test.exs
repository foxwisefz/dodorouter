defmodule DodoRouterWeb.LogsControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = RoutersFixtures.router_fixture(user)
    %{user: user, router: router, api_key: api_key}
  end

  defp auth(conn, api_key), do: put_req_header(conn, "authorization", "Bearer #{api_key}")

  defp evaluable_body do
    Jason.encode!(%{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "How long is the refund window?"}]
    })
  end

  describe "GET /r/:router_slug/logs" do
    test "requires the router API key", %{conn: conn, router: router} do
      conn = get(conn, "/r/#{router.slug}/logs")
      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "lists the router's requests with cost and token figures", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      LogsFixtures.log_fixture(router, %{
        request_body: evaluable_body(),
        estimated_cost_usd: Decimal.new("0.0025")
      })

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs")

      assert %{"data" => [log], "limit" => 20, "offset" => 0, "returned" => 1} =
               json_response(conn, 200)

      assert log["model"] == "test-model"
      assert log["total_tokens"] == 150
      # Money is a JSON number so a caller can sort on it without parsing.
      assert log["cost_usd"] == 0.0025
      assert log["evaluable"] == true
      assert log["not_evaluable_because"] == nil
    end

    test "says why a log can't be evaluated instead of failing at benchmark time", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      LogsFixtures.log_fixture(router)

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs")

      assert %{"data" => [log]} = json_response(conn, 200)
      assert log["evaluable"] == false
      assert log["not_evaluable_because"] =~ "not valid JSON"
    end

    test "a router key cannot read another router's traffic", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key
    } do
      {other_router, _other_key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(other_router, %{request_body: evaluable_body()})

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs")

      assert json_response(conn, 200)["data"] == []
    end

    test "clamps limit so one call can't ask for the whole table", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs?limit=5000")

      assert json_response(conn, 200)["limit"] == 100
    end
  end

  describe "GET /r/:router_slug/logs/:id" do
    test "returns the stored bodies decoded", %{conn: conn, router: router, api_key: api_key} do
      log =
        LogsFixtures.log_fixture(router, %{
          request_body: evaluable_body(),
          response_body:
            Jason.encode!(%{"choices" => [%{"message" => %{"content" => "30 days"}}]})
        })

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs/#{log.id}")

      body = json_response(conn, 200)
      assert body["id"] == log.id
      assert [%{"role" => "user"}] = body["request_body"]["messages"]
      assert [%{"message" => %{"content" => "30 days"}}] = body["response_body"]["choices"]
    end

    test "accepts the request_id the client saw on its own response", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      log = LogsFixtures.log_fixture(router, %{request_body: evaluable_body()})

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs/#{log.request_id}")

      assert json_response(conn, 200)["id"] == log.id
    end

    test "404s for a log on another router, and points at the guide", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key
    } do
      {other_router, _key} = RoutersFixtures.router_fixture(user)
      other_log = LogsFixtures.log_fixture(other_router)

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs/#{other_log.id}")

      body = json_response(conn, 404)
      assert body["error"]["type"] == "not_found"
      assert body["see"] =~ "/r/#{router.slug}/agent"
    end

    test "a malformed id is a 404, not a 500", %{conn: conn, router: router, api_key: api_key} do
      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/logs/not-a-uuid")

      assert json_response(conn, 404)["error"]["type"] == "not_found"
    end
  end
end
