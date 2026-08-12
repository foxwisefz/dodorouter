defmodule DodoRouterWeb.AgentTokenLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.Agents
  alias DodoRouter.AgentsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  describe "minting" do
    test "mints a token scoped to the routers picked", %{conn: conn, user: user} do
      {router, _key} = RoutersFixtures.router_fixture(user)
      {other, _key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      live
      |> form("#mint-token-form", %{
        "token" => %{
          "name" => "Claude Code",
          "scopes" => ["logs:read", "evals:read"],
          "reach" => "selected",
          "router_ids" => [router.id],
          "expires_in_days" => "90"
        }
      })
      |> render_submit()

      assert [token] = Agents.list_tokens(user)
      assert token.name == "Claude Code"
      assert token.scopes == ["logs:read", "evals:read"]
      assert token.router_ids == [router.id]
      refute token.all_routers
      refute other.id in token.router_ids
      assert token.expires_at
    end

    test "shows the secret once, and it is not in the database", %{conn: conn, user: user} do
      {router, _key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      html =
        live
        |> form("#mint-token-form", %{
          "token" => %{
            "name" => "Once only",
            "scopes" => ["logs:read"],
            "reach" => "selected",
            "router_ids" => [router.id],
            "expires_in_days" => "30"
          }
        })
        |> render_submit()

      assert html =~ "dodo_agt_"
      assert has_element?(live, "#new-token-secret")
      assert has_element?(live, "#copy-agent-token")

      # The example command has to be one that works right now, against a
      # router this token can actually reach.
      assert html =~ "/r/#{router.slug}/agent"

      [token] = Agents.list_tokens(user)
      # Reloaded from the database the secret is simply gone, so the banner is
      # genuinely the only chance to copy it.
      refute token.token_hash =~ "dodo_agt_"

      # Dismissing it does not bring it back on re-render.
      live |> element("#new-token-secret button[phx-click='dismiss_secret']") |> render_click()
      refute has_element?(live, "#new-token-secret")
    end

    test "the sensitive scope is not ticked by default", %{conn: conn, user: user} do
      {_router, _key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      # Reading prompts and responses has to be reached for deliberately.
      refute has_element?(
               live,
               "input[name='token[scopes][]'][value='logs:read_bodies'][checked]"
             )

      assert has_element?(live, "input[name='token[scopes][]'][value='logs:read'][checked]")
    end

    test "refuses a token that reaches nothing, without losing what was typed", %{
      conn: conn,
      user: user
    } do
      {_router, _key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      # A router exists; none was ticked, so the checkboxes send nothing. That
      # is the shape a real "I forgot to pick one" submission has.
      html =
        live
        |> form("#mint-token-form", %{
          "token" => %{
            "name" => "Reaches nothing",
            "scopes" => ["logs:read"],
            "reach" => "selected",
            "expires_in_days" => "30"
          }
        })
        |> render_submit()

      assert Agents.list_tokens(user) == []
      assert html =~ "pick at least one router"
      assert html =~ "Reaches nothing"
    end

    test "granting every router is possible but marked as unbounded", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      assert render(live) =~ "Including routers you create later"

      live
      |> form("#mint-token-form", %{
        "token" => %{
          "name" => "Everything",
          "scopes" => ["logs:read"],
          "reach" => "all",
          "expires_in_days" => "never"
        }
      })
      |> render_submit()

      assert [token] = Agents.list_tokens(user)
      assert token.all_routers
      assert token.router_ids == []
      assert token.expires_at == nil
    end
  end

  describe "listing and revoking" do
    test "revoking stops the token but keeps its history", %{conn: conn, user: user} do
      {router, _key} = RoutersFixtures.router_fixture(user)
      {token, raw} = AgentsFixtures.agent_token_fixture(user, %{"name" => "Old laptop"})

      # Give it some history first.
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/r/#{router.slug}/logs")
      |> json_response(200)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")
      assert has_element?(live, "#token-#{token.id}")

      # Revoking asks first — it takes a working credential away.
      live |> element("#token-#{token.id} button[phx-click='confirm_revoke']") |> render_click()
      assert render(live) =~ "Stops working immediately"

      live |> element("#token-#{token.id} button[phx-click='revoke']") |> render_click()

      assert Agents.get_token(user, token.id).revoked_at
      assert [call] = Agents.list_calls(user)
      assert call.agent_token_id == token.id
    end

    test "shows what a token reaches", %{conn: conn, user: user} do
      {router, _key} = RoutersFixtures.router_fixture(user)
      {_token, _raw} = AgentsFixtures.token_for_routers_fixture(user, [router])

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      assert render(live) =~ router.name
    end
  end

  describe "audit trail" do
    test "shows what an agent did, and flags reads that carried bodies", %{
      conn: conn,
      user: user
    } do
      {router, _key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router, %{request_body: ~s({"messages":[]})})
      {_token, raw} = AgentsFixtures.agent_token_fixture(user, %{"name" => "Reader"})

      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/r/#{router.slug}/logs/#{log.id}")
      |> json_response(200)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")
      html = render(live)

      assert html =~ "Reader"
      assert html =~ "GET /r/#{router.slug}/logs/#{log.id}"
      # The badge that answers "when did transcript text leave this system".
      assert html =~ "bodies"
    end

    test "a refused call is shown, and shown as refused", %{conn: conn, user: user} do
      {router, _key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)
      {_token, raw} = AgentsFixtures.scoped_token_fixture(user, ["evals:read"])

      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/r/#{router.slug}/logs/#{log.id}")
      |> json_response(403)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      assert render(live) =~ "denied"
      assert has_element?(live, "tr.bg-error\\/5")
    end

    test "one user cannot see another's tokens or calls", %{conn: conn} do
      stranger = DodoRouter.AccountsFixtures.user_fixture()
      {stranger_router, _key} = RoutersFixtures.router_fixture(stranger)
      {_token, raw} = AgentsFixtures.agent_token_fixture(stranger, %{"name" => "Not yours"})

      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/r/#{stranger_router.slug}/logs")
      |> json_response(200)

      {:ok, live, _html} = live(conn, ~p"/agent-tokens")

      refute render(live) =~ "Not yours"
    end
  end
end
