defmodule DodoRouterWeb.BillingPaywallLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DodoRouter.AccountsFixtures

  setup :register_and_log_in_user

  test "unsubscribed users cannot mount app LiveViews", %{conn: conn, user: user} do
    set_subscription_status(user, nil)

    assert {:error, {:redirect, %{to: "/billing"}}} = live(conn, ~p"/routers")
  end

  test "subscribed users mount app LiveViews", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/routers")
    assert html =~ "router"
  end
end
