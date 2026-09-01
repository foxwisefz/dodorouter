defmodule DodoRouterWeb.BillingControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  import DodoRouter.AccountsFixtures

  alias DodoRouter.Repo

  setup :register_and_log_in_user

  describe "GET /billing" do
    test "renders the plan for an unsubscribed user", %{conn: conn, user: user} do
      set_subscription_status(user, nil)

      conn = get(conn, ~p"/billing")
      response = html_response(conn, 200)
      assert response =~ "$19"
      assert response =~ "billing-subscribe-form"
    end

    test "renders manage button for a subscribed user", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(stripe_customer_id: "cus_ui")
      |> Repo.update!()

      response = conn |> get(~p"/billing") |> html_response(200)
      assert response =~ "billing-portal-form"
    end

    test "requires authentication" do
      conn = build_conn() |> get(~p"/billing")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /billing/checkout" do
    test "redirects to the Stripe checkout URL", %{conn: conn, user: user} do
      conn = post(conn, ~p"/billing/checkout")

      assert redirected_to(conn) == "https://checkout.stripe.com/c/pay/cs_stub"
      assert_received {:stripe_stub, {:create_checkout_session, params}}
      assert params.client_reference_id == user.id
    end

    test "falls back to /billing with a flash on Stripe errors", %{conn: conn} do
      Process.put({:stripe_stub, :list_prices}, {:ok, %{data: []}})

      conn = post(conn, ~p"/billing/checkout")
      assert redirected_to(conn) == ~p"/billing"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "checkout"
    end
  end

  describe "POST /billing/portal" do
    test "redirects to the Stripe billing portal", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(stripe_customer_id: "cus_portal")
      |> Repo.update!()

      conn = post(conn, ~p"/billing/portal")

      assert redirected_to(conn) == "https://billing.stripe.com/p/session/bps_stub"
      assert_received {:stripe_stub, {:create_billing_portal_session, %{customer: "cus_portal"}}}
    end

    test "without a Stripe customer redirects back to /billing", %{conn: conn} do
      conn = post(conn, ~p"/billing/portal")
      assert redirected_to(conn) == ~p"/billing"
    end
  end

  describe "paywall" do
    test "unsubscribed browser users are redirected to /billing", %{conn: conn, user: user} do
      set_subscription_status(user, nil)

      for path <- [~p"/routers", ~p"/dashboard", ~p"/logs"] do
        conn = get(conn, path)
        assert redirected_to(conn) == ~p"/billing"
      end
    end

    test "subscribed users reach the app", %{conn: conn} do
      conn = get(conn, ~p"/routers")
      assert html_response(conn, 200)
    end

    test "unsubscribed users can still reach settings and log out", %{conn: conn, user: user} do
      set_subscription_status(user, nil)

      assert conn |> get(~p"/users/settings") |> html_response(200)
    end
  end
end
