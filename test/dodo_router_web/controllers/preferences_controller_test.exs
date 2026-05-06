defmodule DodoRouterWeb.PreferencesControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  setup :register_and_log_in_user

  describe "PUT /preferences (sidebar_collapsed)" do
    test "updates sidebar_collapsed to true", %{conn: conn, user: user} do
      conn = put(conn, ~p"/preferences", %{sidebar_collapsed: true})
      assert json_response(conn, 200) == %{"ok" => true}

      updated = DodoRouter.Accounts.get_user!(user.id)
      assert updated.sidebar_collapsed == true
    end

    test "updates sidebar_collapsed to false", %{conn: conn, user: user} do
      DodoRouter.Accounts.update_user_preferences(user, %{sidebar_collapsed: true})

      conn = put(conn, ~p"/preferences", %{sidebar_collapsed: false})
      assert json_response(conn, 200) == %{"ok" => true}

      updated = DodoRouter.Accounts.get_user!(user.id)
      assert updated.sidebar_collapsed == false
    end
  end

  describe "PUT /preferences (theme)" do
    test "updates theme to dark", %{conn: conn, user: user} do
      conn = put(conn, ~p"/preferences", %{theme: "dark"})
      assert json_response(conn, 200) == %{"ok" => true}

      updated = DodoRouter.Accounts.get_user!(user.id)
      assert updated.theme == "dark"
    end

    test "updates theme to system", %{conn: conn, user: user} do
      conn = put(conn, ~p"/preferences", %{theme: "system"})
      assert json_response(conn, 200) == %{"ok" => true}

      updated = DodoRouter.Accounts.get_user!(user.id)
      assert updated.theme == "system"
    end

    test "rejects invalid theme", %{conn: conn} do
      conn = put(conn, ~p"/preferences", %{theme: "neon"})
      assert json_response(conn, 422)
    end
  end

  describe "PUT /preferences (auth)" do
    test "redirects when not logged in" do
      conn = build_conn()
      conn = put(conn, ~p"/preferences", %{theme: "dark"})
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "PUT /preferences (invalid params)" do
    test "returns 400 for unknown params", %{conn: conn} do
      conn = put(conn, ~p"/preferences", %{foo: "bar"})
      assert json_response(conn, 400) == %{"error" => "invalid params"}
    end
  end
end
