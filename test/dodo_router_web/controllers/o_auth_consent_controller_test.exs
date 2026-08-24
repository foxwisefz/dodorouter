defmodule DodoRouterWeb.OAuthConsentControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  import DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  @approve_params %{
    "decision" => "approve",
    "client_id" => "test-client",
    "redirect_uri" => "http://127.0.0.1:33418/callback",
    "response_type" => "code",
    "granted_scopes" => ["logs:read"]
  }

  defp granted_scope(conn) do
    assert to = redirected_to(conn)
    assert %{query: query} = URI.parse(to)
    URI.decode_query(query)["scope"]
  end

  describe "router narrowing on the consent screen" do
    test "shows the router picker with the user's routers", %{conn: conn, user: user} do
      {router, _key} = router_fixture(user)

      conn = get(conn, ~p"/oauth/consent", %{"client_id" => "c", "scope" => "logs:read"})
      html = html_response(conn, 200)

      assert html =~ "Which routers"
      assert html =~ router.slug
      assert html =~ ~s(name="router_access")
    end

    test "hides the picker when the account has no routers", %{conn: conn} do
      conn = get(conn, ~p"/oauth/consent", %{"client_id" => "c", "scope" => "logs:read"})

      refute html_response(conn, 200) =~ "Which routers"
    end

    test "a re-requested router scope preselects the picker, not a permission row", %{
      conn: conn,
      user: user
    } do
      {router, _key} = router_fixture(user)

      conn =
        get(conn, ~p"/oauth/consent", %{
          "client_id" => "c",
          "scope" => "logs:read router:" <> router.id
        })

      html = html_response(conn, 200)

      # Preselected in the picker…
      assert html =~ ~s(name="granted_routers[]" value="#{router.id}" checked)
      assert html =~ ~s(name="router_access" value="selected" checked)
      # …and never rendered as a permission checkbox.
      refute html =~ ~s(value="router:#{router.id}")
    end
  end

  describe "POST /oauth/consent router narrowing" do
    test "granting all routers adds no router scopes", %{conn: conn, user: user} do
      {_router, _key} = router_fixture(user)

      conn = post(conn, ~p"/oauth/consent", Map.put(@approve_params, "router_access", "all"))

      assert granted_scope(conn) == "logs:read"
    end

    test "selecting routers appends their scopes to the grant", %{conn: conn, user: user} do
      {router, _key} = router_fixture(user)

      params =
        @approve_params
        |> Map.put("router_access", "selected")
        |> Map.put("granted_routers", [router.id])

      conn = post(conn, ~p"/oauth/consent", params)

      assert granted_scope(conn) == "logs:read router:" <> router.id
    end

    test "selected with nothing ticked re-renders with an error", %{conn: conn, user: user} do
      {_router, _key} = router_fixture(user)

      params = Map.put(@approve_params, "router_access", "selected")
      conn = post(conn, ~p"/oauth/consent", params)

      assert html_response(conn, 200) =~ "Pick at least one router"
    end

    test "somebody else's router id cannot be granted", %{conn: conn} do
      {other, _key} = router_fixture()

      params =
        @approve_params
        |> Map.put("router_access", "selected")
        |> Map.put("granted_routers", [other.id])

      conn = post(conn, ~p"/oauth/consent", params)

      assert html_response(conn, 200) =~ "Pick at least one router"
    end

    test "router scopes smuggled through the permission checkboxes are dropped", %{
      conn: conn,
      user: user
    } do
      {router, _key} = router_fixture(user)

      params = Map.put(@approve_params, "granted_scopes", ["logs:read", "router:" <> router.id])
      conn = post(conn, ~p"/oauth/consent", params)

      assert granted_scope(conn) == "logs:read"
    end
  end

  describe "GET /oauth/consent branding" do
    test "renders the Dodo wordmark and logo", %{conn: conn} do
      conn = get(conn, ~p"/oauth/consent", %{"client_id" => "unknown-client"})
      html = html_response(conn, 200)

      assert html =~ "DodoRouter"
      assert html =~ "font-family: 'Poppins', sans-serif;"
      assert html =~ "<svg"
    end

    test "includes a favicon link", %{conn: conn} do
      conn = get(conn, ~p"/oauth/consent", %{"client_id" => "unknown-client"})
      html = html_response(conn, 200)

      assert html =~ ~s(rel="icon")
    end

    test "reflects the signed-in user's theme in data-theme", %{conn: conn, user: user} do
      {:ok, _user} = DodoRouter.Accounts.update_user_preferences(user, %{theme: "dark"})

      conn = get(conn, ~p"/oauth/consent", %{"client_id" => "unknown-client"})
      html = html_response(conn, 200)

      assert html =~ ~s(data-theme="dark")
    end

    test "does not load app.js, keeping the page standalone", %{conn: conn} do
      conn = get(conn, ~p"/oauth/consent", %{"client_id" => "unknown-client"})
      html = html_response(conn, 200)

      refute html =~ "/assets/js/app.js"
    end
  end
end
