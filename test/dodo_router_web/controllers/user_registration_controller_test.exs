defmodule DodoRouterWeb.UserRegistrationControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  import DodoRouter.AccountsFixtures

  describe "GET /users/register" do
    test "renders registration page", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ ~p"/users/log-in"
      assert response =~ ~p"/users/register"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/users/register")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /users/register" do
    @tag :capture_log
    test "creates account but does not log in", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => valid_user_attributes(email: email)
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"

      assert conn.assigns.flash["info"] =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "render errors for invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ "must have the @ sign and no spaces"
    end

    test "duplicate email suggests logging in and keeps the ToS box checked", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => user.email, "tos_accepted" => "true"}
        })

      response = html_response(conn, 200)
      refute response =~ "has already been taken"
      assert response =~ "already registered"
      assert response =~ ~s(href="/users/log-in")
      # The accepted ToS checkbox must survive the error re-render
      assert response =~ ~r/<input[^>]*name="user\[tos_accepted\]"[^>]*checked/s
    end
  end
end
