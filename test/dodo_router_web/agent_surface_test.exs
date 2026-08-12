defmodule DodoRouterWeb.AgentSurfaceTest do
  @moduledoc """
  The credential and audit rules for the agent surface, tested through the
  endpoints rather than against the plugs in isolation — a scope check that
  passes in a unit test but is never reached by a route protects nothing.
  """

  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.Agents
  alias DodoRouter.Agents.ApiCall
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.AgentsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.Repo
  alias DodoRouter.RoutersFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {router, proxy_key} = RoutersFixtures.router_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "the customer's actual question"}]
          }),
        response_body: Jason.encode!(%{"choices" => [%{"message" => %{"content" => "30 days"}}]})
      })

    %{user: user, router: router, proxy_key: proxy_key, log: log}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp calls(user), do: Agents.list_calls(user)

  describe "audit" do
    test "records a successful call with what it touched", %{
      conn: conn,
      user: user,
      router: router,
      log: log
    } do
      {token, raw} = AgentsFixtures.agent_token_fixture(user, %{"name" => "Claude Code"})

      conn |> auth(raw) |> get("/r/#{router.slug}/logs/#{log.id}") |> json_response(200)

      assert [call] = calls(user)
      assert call.outcome == "ok"
      assert call.http_status == 200
      assert call.principal_kind == "agent_token"
      assert call.principal_name == "Claude Code"
      assert call.agent_token_id == token.id
      assert call.router_id == router.id
      assert call.target_type == "request_log"
      assert call.target_id == log.id
      assert call.interface == "rest"
      assert call.operation == "GET /r/#{router.slug}/logs/#{log.id}"
      # The read carried the product's real traffic, and says so.
      assert call.returned_bodies
    end

    test "records a call refused for a bad token", %{conn: conn, user: user, router: router} do
      conn |> auth("dodo_agt_nonsense") |> get("/r/#{router.slug}/logs") |> json_response(401)

      # No principal resolved, so it cannot be attributed to a user — but the
      # attempt is still on the record.
      assert [call] = Repo.all(ApiCall)
      assert call.outcome == "denied"
      assert call.principal_kind == "unauthenticated"
      assert call.user_id == nil
      assert calls(user) == []
    end

    test "records a call refused for a missing scope", %{
      conn: conn,
      user: user,
      router: router,
      log: log
    } do
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["evals:read"])

      conn |> auth(raw) |> get("/r/#{router.slug}/logs/#{log.id}") |> json_response(403)

      assert [call] = calls(user)
      assert call.outcome == "denied"
      assert call.http_status == 403
      # Recorded as the scopes actually held, so a later grant doesn't rewrite
      # what this attempt was allowed to do at the time.
      assert call.scopes == ["evals:read"]
      refute call.returned_bodies
    end

    test "a metadata-only read is not recorded as carrying bodies", %{
      conn: conn,
      user: user,
      router: router
    } do
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["logs:read"])

      conn |> auth(raw) |> get("/r/#{router.slug}/logs") |> json_response(200)

      assert [call] = calls(user)
      assert call.outcome == "ok"
      refute call.returned_bodies
    end

    test "survives the token it describes being revoked", %{
      conn: conn,
      user: user,
      router: router
    } do
      {token, raw} = AgentsFixtures.agent_token_fixture(user)
      conn |> auth(raw) |> get("/r/#{router.slug}/logs") |> json_response(200)

      {:ok, _revoked} = Agents.revoke_token(user, token.id)

      # Revoking is exactly when the history becomes worth reading.
      assert [call] = calls(user)
      assert call.agent_token_id == token.id
    end
  end

  describe "self-onboarding" do
    test "a token with only a base url can find its routers", %{
      conn: conn,
      user: user,
      router: router
    } do
      {second, _key} = RoutersFixtures.router_fixture(user)
      {_token, raw} = AgentsFixtures.token_for_routers_fixture(user, [router, second])

      body = conn |> auth(raw) |> get("/agent") |> json_response(200)

      slugs = Enum.map(body["routers"], & &1["slug"])
      assert router.slug in slugs
      assert second.slug in slugs

      # Each entry hands over the URL of its own guide, so the next call needs
      # no construction by the caller.
      assert Enum.all?(body["routers"], &String.ends_with?(&1["guide"], "/agent"))
      assert body["next"] =~ "/agent"
    end

    test "names the scopes it holds and the vocabulary of the rest", %{conn: conn, user: user} do
      {_token, raw} =
        AgentsFixtures.scoped_token_fixture(user, ["logs:read"], %{"name" => "Reader"})

      body = conn |> auth(raw) |> get("/agent") |> json_response(200)

      assert body["token"]["name"] == "Reader"
      assert body["token"]["scopes"] == ["logs:read"]
      # The full vocabulary, so a 403 later is actionable rather than cryptic.
      assert "logs:read_bodies" in Enum.map(body["scopes"], & &1["name"])
      assert Enum.any?(body["scopes"], &(&1["name"] == "logs:read_bodies" and &1["sensitive"]))
    end

    test "says so when a token reaches nothing rather than returning a bare empty list", %{
      conn: conn,
      user: user
    } do
      {router, _key} = RoutersFixtures.router_fixture(user)
      {_token, raw} = AgentsFixtures.token_for_routers_fixture(user, [router])
      DodoRouter.Repo.delete!(router)

      body = conn |> auth(raw) |> get("/agent") |> json_response(200)

      assert body["routers"] == []
      assert body["next"] =~ "reaches no routers"
    end

    test "still requires a credential, and points a refused caller somewhere fetchable", %{
      conn: conn
    } do
      body = conn |> get("/agent") |> json_response(401)

      # Not the browser page — a program cannot use that.
      assert body["see"] =~ "/agent"
      refute body["see"] =~ "agent-tokens"
    end
  end

  describe "scopes" do
    test "withholds bodies visibly rather than omitting them", %{
      conn: conn,
      user: user,
      router: router,
      log: log
    } do
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["logs:read"])

      body =
        conn |> auth(raw) |> get("/r/#{router.slug}/logs/#{log.id}") |> json_response(200)

      # Metadata still flows — this token can rank models on price.
      assert body["model"] == "test-model"
      assert body["total_tokens"] == 150

      # But the transcript does not, and the key says why instead of vanishing.
      assert body["request_body"] == %{"withheld" => "requires the logs:read_bodies scope"}
      assert body["response_body"] == %{"withheld" => "requires the logs:read_bodies scope"}
      refute inspect(body) =~ "the customer's actual question"
    end

    test "the bodies scope opens the transcript", %{
      conn: conn,
      user: user,
      router: router,
      log: log
    } do
      {_token, raw} =
        AgentsFixtures.scoped_token_fixture(user, ["logs:read", "logs:read_bodies"])

      body =
        conn |> auth(raw) |> get("/r/#{router.slug}/logs/#{log.id}") |> json_response(200)

      assert [%{"content" => "the customer's actual question"}] = body["request_body"]["messages"]
    end

    test "a 403 names the scope that would have worked", %{
      conn: conn,
      user: user,
      router: router
    } do
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["logs:read"])

      conn = conn |> auth(raw) |> get("/r/#{router.slug}/evals")

      body = json_response(conn, 403)
      assert body["error"]["type"] == "insufficient_scope"
      assert body["error"]["required_scopes"] == ["evals:read"]

      # RFC 6750 shape, so an OAuth client could act on it unchanged.
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="evals:read")
    end

    test "reading is not writing: evals:read cannot start a benchmark", %{
      conn: conn,
      user: user,
      router: router,
      log: log
    } do
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["evals:read"])

      conn =
        conn
        |> auth(raw)
        |> post("/r/#{router.slug}/evals", %{"request_log_id" => log.id, "name" => "nope"})

      assert json_response(conn, 403)["error"]["required_scopes"] == ["evals:write"]
    end

    test "reading the guide needs no scope beyond a valid credential", %{
      conn: conn,
      user: user,
      router: router
    } do
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["logs:read"])

      assert conn |> auth(raw) |> get("/r/#{router.slug}/agent") |> json_response(200)
    end
  end

  describe "credential lifecycle" do
    test "a revoked token stops working and says so", %{conn: conn, user: user, router: router} do
      {token, raw} = AgentsFixtures.agent_token_fixture(user)
      {:ok, _} = Agents.revoke_token(user, token.id)

      body = conn |> auth(raw) |> get("/r/#{router.slug}/logs") |> json_response(401)
      assert body["error"]["message"] =~ "revoked"
    end

    test "an expired token stops working and says so", %{conn: conn, user: user, router: router} do
      {token, raw} = AgentsFixtures.agent_token_fixture(user)

      token
      |> Ecto.Changeset.change(
        expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      body = conn |> auth(raw) |> get("/r/#{router.slug}/logs") |> json_response(401)
      assert body["error"]["message"] =~ "expired"
    end

    test "the raw secret is never stored", %{user: user} do
      {token, raw} = AgentsFixtures.agent_token_fixture(user)

      stored = Repo.get!(DodoRouter.Agents.AgentToken, token.id)
      refute stored.token_hash == raw
      refute stored.token_prefix == raw
      assert String.starts_with?(raw, "dodo_agt_")
      # Reloaded from the database, the secret is simply gone.
      assert stored.token == nil
    end

    test "one token reaches every router of the app it was minted for", %{
      conn: conn,
      user: user,
      router: router
    } do
      # An app is usually several routers — one per module — and an agent
      # working on it should not need a credential per module.
      {second_module, _key} = RoutersFixtures.router_fixture(user)
      {other_app, _key} = RoutersFixtures.router_fixture(user)

      {_token, raw} =
        AgentsFixtures.token_for_routers_fixture(user, [router, second_module])

      assert conn |> auth(raw) |> get("/r/#{router.slug}/logs") |> json_response(200)
      assert conn |> auth(raw) |> get("/r/#{second_module.slug}/logs") |> json_response(200)

      # Same owner, same account — but a different app, and this credential
      # was not granted it.
      assert conn |> auth(raw) |> get("/r/#{other_app.slug}/logs") |> json_response(404)
    end

    test "all_routers covers a router created after the token was minted", %{
      conn: conn,
      user: user
    } do
      {_token, raw} = AgentsFixtures.agent_token_fixture(user, %{"all_routers" => true})
      {later, _key} = RoutersFixtures.router_fixture(user)

      # This is the unbounded grant, and it is exactly why it has to be an
      # explicit tick rather than what an empty router list happens to mean.
      assert conn |> auth(raw) |> get("/r/#{later.slug}/logs") |> json_response(200)
    end

    test "a listed router does not cover one created later", %{conn: conn, user: user} do
      {first, _key} = RoutersFixtures.router_fixture(user)
      {_token, raw} = AgentsFixtures.token_for_routers_fixture(user, [first])
      {later, _key} = RoutersFixtures.router_fixture(user)

      assert conn |> auth(raw) |> get("/r/#{later.slug}/logs") |> json_response(404)
    end

    test "a token must say what it reaches", %{user: user} do
      assert {:error, changeset} =
               Agents.create_token(user, %{
                 "name" => "reaches nothing",
                 "scopes" => ["logs:read"],
                 "all_routers" => false,
                 "router_ids" => []
               })

      assert {"pick at least one router, or grant all routers", _} = changeset.errors[:router_ids]
    end

    test "a token cannot name a router its owner does not have", %{conn: _conn, user: user} do
      stranger = AccountsFixtures.user_fixture()
      {stranger_router, _key} = RoutersFixtures.router_fixture(stranger)

      assert {:error, changeset} =
               Agents.create_token(user, %{
                 "name" => "not mine",
                 "scopes" => ["logs:read"],
                 "all_routers" => false,
                 "router_ids" => [stranger_router.id]
               })

      assert changeset.errors[:router_ids]
    end

    test "a token cannot reach another user's router", %{conn: conn, user: user} do
      stranger = AccountsFixtures.user_fixture()
      {stranger_router, _key} = RoutersFixtures.router_fixture(stranger)
      {_token, raw} = AgentsFixtures.agent_token_fixture(user)

      assert conn |> auth(raw) |> get("/r/#{stranger_router.slug}/logs") |> json_response(404)
    end

    test "the router's proxy key is not an agent credential", %{
      conn: conn,
      router: router,
      proxy_key: proxy_key
    } do
      # The regression this whole surface exists to prevent: a key that sends
      # traffic must not read it back.
      assert conn |> auth(proxy_key) |> get("/r/#{router.slug}/logs") |> json_response(401)
    end

    test "the proxy endpoints still take the proxy key", %{
      conn: conn,
      router: router,
      proxy_key: proxy_key
    } do
      # ...and the regate must not have broken what that key is actually for.
      assert conn |> auth(proxy_key) |> get("/r/#{router.slug}/v1/models") |> json_response(200)
    end
  end
end
