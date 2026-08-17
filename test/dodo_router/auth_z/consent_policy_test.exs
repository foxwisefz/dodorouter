defmodule DodoRouter.AuthZ.ConsentPolicyTest do
  @moduledoc """
  The callbacks attesto drives the authorization endpoint through.

  Written after both of them 500'd against a real client: the contract
  documents `auth_opts` loosely, attesto passes a map, and guessing keyword
  list turned a login redirect into a FunctionClauseError on the one endpoint a
  user actually sees.
  """

  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.AuthZ.{ConsentPolicy, PrincipalStore}

  # A session, because the real conn reaches this through :oauth_interactive
  # which fetches one — and to_login/1 stores the return path in it.
  defp conn_with(user) do
    scope = if user, do: %{user: user}, else: nil

    Phoenix.ConnTest.build_conn()
    |> Map.put(:params, %{})
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.assign(:current_scope, scope)
  end

  describe "authenticate_resource_owner/3" do
    test "authenticates a signed-in user, with opts as a map" do
      user = AccountsFixtures.user_fixture()

      # The exact shape attesto sends.
      opts = %{interactive: true, prompt: ["consent"], max_age: nil, force_reauth: false}

      assert {:authenticated, %{subject: subject}} =
               ConsentPolicy.authenticate_resource_owner(conn_with(user), %{}, opts)

      assert subject == PrincipalStore.subject_for(user)
    end

    test "accepts a keyword list too" do
      user = AccountsFixtures.user_fixture()

      assert {:authenticated, _} =
               ConsentPolicy.authenticate_resource_owner(conn_with(user), %{},
                 interactive: true,
                 force_reauth: false
               )
    end

    test "redirects to login when nobody is signed in" do
      assert {:halt, conn} =
               ConsentPolicy.authenticate_resource_owner(conn_with(nil), %{}, %{interactive: true})

      assert conn.halted
      assert Phoenix.ConnTest.redirected_to(conn) == "/users/log-in"
    end

    test "prompt=none reports login_required rather than showing UI" do
      # The client explicitly asked for no interaction; redirecting into a login
      # page would ignore that.
      assert {:error, :login_required} =
               ConsentPolicy.authenticate_resource_owner(conn_with(nil), %{}, %{
                 interactive: false
               })
    end

    test "force_reauth sends a signed-in user back through login" do
      user = AccountsFixtures.user_fixture()

      assert {:halt, _conn} =
               ConsentPolicy.authenticate_resource_owner(conn_with(user), %{}, %{
                 interactive: true,
                 force_reauth: true
               })
    end
  end
end
