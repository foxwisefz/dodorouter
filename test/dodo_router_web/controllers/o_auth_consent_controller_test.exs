defmodule DodoRouterWeb.OAuthConsentControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  setup :register_and_log_in_user

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
