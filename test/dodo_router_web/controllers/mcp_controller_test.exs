defmodule DodoRouterWeb.MCPControllerTest do
  @moduledoc """
  The 2026-07-28 transport rules. These are the parts a hand-rolled protocol
  gets wrong quietly — a header the server forgot to compare against the body
  is invisible until an intermediary routes on one and the server acts on the
  other.
  """

  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.Agents
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.AgentsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  @version "2026-07-28"

  setup do
    user = AccountsFixtures.user_fixture()
    {router, _proxy_key} = RoutersFixtures.router_fixture(user)
    {_token, raw} = AgentsFixtures.token_for_routers_fixture(user, [router])

    %{user: user, router: router, token: raw}
  end

  # Builds a spec-shaped request: the mirrored headers are derived from the
  # body, exactly as a conforming client must derive them.
  defp rpc(conn, token, method, params \\ nil, opts \\ []) do
    id = Keyword.get(opts, :id, 1)
    version = Keyword.get(opts, :version, @version)

    body =
      %{"jsonrpc" => "2.0", "method" => method}
      |> then(&if id, do: Map.put(&1, "id", id), else: &1)
      |> then(&if params, do: Map.put(&1, "params", params), else: &1)

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("mcp-protocol-version", Keyword.get(opts, :protocol_header, version))
    |> put_req_header("mcp-method", Keyword.get(opts, :method_header, method))
    |> then(fn c ->
      case Keyword.get(opts, :name_header, params && params["name"]) do
        nil -> c
        name -> put_req_header(c, "mcp-name", name)
      end
    end)
    |> then(fn c ->
      case opts[:origin] do
        nil -> c
        origin -> put_req_header(c, "origin", origin)
      end
    end)
    |> post("/mcp", body)
  end

  defp tool_json(response) do
    response["result"]["structuredContent"]
  end

  describe "transport rules" do
    test "requires a credential", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "tools/list")
        |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end

    test "GET and DELETE are 405 — those were the removed session verbs", %{
      conn: conn,
      token: token
    } do
      authed = put_req_header(conn, "authorization", "Bearer #{token}")

      for c <- [get(authed, "/mcp"), delete(authed, "/mcp")] do
        assert json_response(c, 405)["error"]["message"] =~ "POST only"
        assert get_resp_header(c, "allow") == ["POST"]
      end
    end

    test "rejects a missing protocol version header", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("mcp-method", "tools/list")
        |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert json_response(conn, 400)["error"]["code"] == -32_020
    end

    test "reports its supported versions when asked for another", %{conn: conn, token: token} do
      conn = rpc(conn, token, "tools/list", nil, protocol_header: "2025-11-25")

      error = json_response(conn, 400)["error"]
      assert error["data"]["supported"] == [@version]
      assert error["data"]["requested"] == "2025-11-25"
    end

    test "rejects a protocol version header that disagrees with the body", %{
      conn: conn,
      token: token
    } do
      params = %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2025-11-25"}}
      conn = rpc(conn, token, "tools/list", params)

      assert json_response(conn, 400)["error"]["code"] == -32_020
    end

    test "rejects an Mcp-Method header that disagrees with the body", %{conn: conn, token: token} do
      conn = rpc(conn, token, "tools/list", nil, method_header: "tools/call")

      error = json_response(conn, 400)["error"]
      assert error["code"] == -32_020
      assert error["message"] =~ "Mcp-Method"
    end

    test "rejects an Mcp-Name header that disagrees with the body", %{conn: conn, token: token} do
      params = %{"name" => "list_routers", "arguments" => %{}}
      conn = rpc(conn, token, "tools/call", params, name_header: "get_log")

      error = json_response(conn, 400)["error"]
      assert error["code"] == -32_020
      assert error["message"] =~ "Mcp-Name"
    end

    test "decodes a base64-wrapped Mcp-Name before comparing", %{conn: conn, token: token} do
      params = %{"name" => "list_routers", "arguments" => %{}}
      wrapped = "=?base64?" <> Base.encode64("list_routers") <> "?="

      conn = rpc(conn, token, "tools/call", params, name_header: wrapped)

      # A plain string comparison would call this a mismatch.
      assert json_response(conn, 200)["result"]["isError"] == false
    end

    test "a notification is accepted with 202 and no body", %{conn: conn, token: token} do
      conn = rpc(conn, token, "notifications/whatever", nil, id: nil)

      assert response(conn, 202) == ""
    end

    test "an unimplemented method is 404 with -32601 and says what exists", %{
      conn: conn,
      token: token
    } do
      conn = rpc(conn, token, "resources/list")

      error = json_response(conn, 404)["error"]
      assert error["code"] == -32_601
      assert "tools/call" in error["data"]["implemented"]
    end

    test "a foreign Origin is refused", %{conn: conn, token: token} do
      conn = rpc(conn, token, "tools/list", nil, origin: "https://evil.example")

      assert json_response(conn, 403)["error"]["message"] =~ "not allowed"
    end

    test "ping works", %{conn: conn, token: token} do
      assert json_response(rpc(conn, token, "ping"), 200)["result"]
    end
  end

  describe "tools/list" do
    test "lists every tool, marking the ones this token cannot use", %{
      conn: conn,
      user: user,
      router: router
    } do
      {_t, limited} =
        AgentsFixtures.token_for_routers_fixture(user, [router], %{"scopes" => ["logs:read"]})

      tools = json_response(rpc(conn, limited, "tools/list"), 200)["result"]["tools"]
      by_name = Map.new(tools, &{&1["name"], &1})

      # Hiding unusable tools would make a missing scope look like a missing
      # feature; naming the scope tells the agent what to ask its user for.
      assert by_name["list_logs"]["description"] =~ "requests this router served"
      refute by_name["list_logs"]["description"] =~ "UNAVAILABLE"
      assert by_name["create_eval"]["description"] =~ "UNAVAILABLE"
      assert by_name["create_eval"]["description"] =~ "evals:write"

      assert by_name["get_log"]["inputSchema"]["required"] == ["id"]
    end
  end

  describe "tools/call" do
    defp call_tool(conn, token, name, args \\ %{}) do
      rpc(conn, token, "tools/call", %{"name" => name, "arguments" => args})
    end

    test "list_routers returns what the token reaches", %{
      conn: conn,
      token: token,
      router: router
    } do
      body = json_response(call_tool(conn, token, "list_routers"), 200)

      assert body["result"]["isError"] == false
      assert [%{"slug" => slug}] = tool_json(body)["routers"]
      assert slug == router.slug
      # Text content mirrors the structured payload for clients that only render text.
      assert [%{"type" => "text", "text" => text}] = body["result"]["content"]
      assert text =~ router.slug
    end

    test "the router argument is optional with one router and required with several", %{
      conn: conn,
      user: user,
      router: router
    } do
      {second, _key} = RoutersFixtures.router_fixture(user)
      LogsFixtures.log_fixture(router)

      {_t, one} = AgentsFixtures.token_for_routers_fixture(user, [router])
      body = json_response(call_tool(conn, one, "list_logs"), 200)
      assert body["result"]["isError"] == false
      assert tool_json(body)["router"] == router.slug

      {_t, many} = AgentsFixtures.token_for_routers_fixture(user, [router, second])
      body = json_response(call_tool(conn, many, "list_logs"), 200)
      # Ambiguous rather than guessed: picking one silently would attribute
      # results to a router the caller never named.
      assert body["result"]["isError"]
      assert hd(body["result"]["content"])["text"] =~ "`router` is required"
    end

    test "a missing scope is an isError result, not a transport failure", %{
      conn: conn,
      user: user,
      router: router
    } do
      {_t, limited} =
        AgentsFixtures.token_for_routers_fixture(user, [router], %{"scopes" => ["logs:read"]})

      body = json_response(call_tool(conn, limited, "list_evals"), 200)

      # 200 with isError so the model reads the reason and can adapt; a bare
      # 403 would tell it only that something broke.
      assert body["result"]["isError"]
      assert hd(body["result"]["content"])["text"] =~ "evals:read"
    end

    test "get_log withholds bodies visibly without the scope", %{
      conn: conn,
      user: user,
      router: router
    } do
      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "secret"}]})
        })

      {_t, limited} =
        AgentsFixtures.token_for_routers_fixture(user, [router], %{"scopes" => ["logs:read"]})

      body = json_response(call_tool(conn, limited, "get_log", %{"id" => log.id}), 200)
      payload = tool_json(body)

      assert payload["total_tokens"] == 150
      assert payload["request_body"]["withheld"] =~ "logs:read_bodies"
      refute inspect(payload) =~ "secret"
    end

    test "an unknown tool names the way to find the real ones", %{conn: conn, token: token} do
      body = json_response(call_tool(conn, token, "delete_everything"), 200)

      assert body["result"]["isError"]
      assert hd(body["result"]["content"])["text"] =~ "tools/list"
    end

    test "a log on another router is not reachable", %{conn: conn, user: user, token: token} do
      {other, _key} = RoutersFixtures.router_fixture(user)
      other_log = LogsFixtures.log_fixture(other)

      body = json_response(call_tool(conn, token, "get_log", %{"id" => other_log.id}), 200)

      assert body["result"]["isError"]
    end
  end

  describe "audit" do
    test "records the tool by name, under the mcp interface", %{
      conn: conn,
      user: user,
      token: token,
      router: router
    } do
      log = LogsFixtures.log_fixture(router, %{request_body: ~s({"messages":[]})})

      call_tool(conn, token, "get_log", %{"id" => log.id})

      assert [call] = Agents.list_calls(user)
      assert call.interface == "mcp"
      assert call.operation == "tools/call"
      assert call.tool == "get_log"
      assert call.target_type == "request_log"
      assert call.target_id == log.id
      assert call.returned_bodies
    end

    test "records a refused call with no credential", %{conn: conn} do
      conn
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", "tools/list")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert [call] = DodoRouter.Repo.all(DodoRouter.Agents.ApiCall)
      assert call.interface == "mcp"
      assert call.outcome == "denied"
    end
  end
end
