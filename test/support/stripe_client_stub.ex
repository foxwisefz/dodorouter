defmodule DodoRouter.Billing.StripeClient.Stub do
  @moduledoc """
  Test double for `DodoRouter.Billing.StripeClient`.

  Every call notifies the calling process with `{:stripe_stub, {fun, params}}`
  so tests can `assert_received` the params. Responses default to canned
  successes; a test can override one via
  `Process.put({:stripe_stub, :list_prices}, {:ok, %{data: []}})`.
  """

  @behaviour DodoRouter.Billing.StripeClient

  @impl true
  def list_prices(params) do
    notify({:list_prices, params})
    respond(:list_prices, {:ok, %{data: [%{id: "price_stub_19"}]}})
  end

  @impl true
  def create_checkout_session(params) do
    notify({:create_checkout_session, params})

    respond(
      :create_checkout_session,
      {:ok, %{id: "cs_stub", url: "https://checkout.stripe.com/c/pay/cs_stub"}}
    )
  end

  @impl true
  def create_billing_portal_session(params) do
    notify({:create_billing_portal_session, params})

    respond(
      :create_billing_portal_session,
      {:ok, %{id: "bps_stub", url: "https://billing.stripe.com/p/session/bps_stub"}}
    )
  end

  defp notify(message), do: send(self(), {:stripe_stub, message})

  defp respond(fun, default), do: Process.get({:stripe_stub, fun}, default)
end
