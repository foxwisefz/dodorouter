defmodule DodoRouterWeb.BillingController do
  use DodoRouterWeb, :controller

  alias DodoRouter.Billing

  def show(conn, params) do
    user = conn.assigns.current_scope.user

    render(conn, :show,
      page_title: "Billing",
      subscribed?: Billing.subscribed?(user) and Billing.enabled?(),
      billing_enabled?: Billing.enabled?(),
      has_customer?: user.stripe_customer_id != nil,
      subscription_status: user.subscription_status,
      period_end: user.subscription_current_period_end,
      checkout_status: params["checkout"]
    )
  end

  def checkout(conn, _params) do
    user = conn.assigns.current_scope.user

    case Billing.create_checkout_session(user, DodoRouterWeb.Endpoint.url()) do
      {:ok, %{url: url}} when is_binary(url) ->
        redirect(conn, external: url)

      {:error, reason} ->
        conn
        |> put_flash(:error, checkout_error_message(reason))
        |> redirect(to: ~p"/billing")
    end
  end

  def portal(conn, _params) do
    user = conn.assigns.current_scope.user

    case Billing.create_portal_session(user, DodoRouterWeb.Endpoint.url()) do
      {:ok, %{url: url}} when is_binary(url) ->
        redirect(conn, external: url)

      {:error, :no_customer} ->
        conn
        |> put_flash(:error, "No billing account found — subscribe first.")
        |> redirect(to: ~p"/billing")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not open the billing portal. Please try again.")
        |> redirect(to: ~p"/billing")
    end
  end

  defp checkout_error_message(:price_not_found) do
    "Could not start checkout: the subscription plan is not configured. Please contact support."
  end

  defp checkout_error_message(_reason) do
    "Could not start checkout. Please try again."
  end
end
