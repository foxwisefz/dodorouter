defmodule DodoRouter.Billing.StripeClient.Live do
  @moduledoc false

  @behaviour DodoRouter.Billing.StripeClient

  @impl true
  def list_prices(params), do: Stripe.Price.list(params)

  @impl true
  def create_checkout_session(params), do: Stripe.Checkout.Session.create(params)

  @impl true
  def create_billing_portal_session(params), do: Stripe.BillingPortal.Session.create(params)
end
