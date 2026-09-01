defmodule DodoRouter.Billing.StripeClient do
  @moduledoc """
  Behaviour for the subset of the Stripe API used by billing.

  The implementation is selected via `config :dodo_router, :stripe_client` so
  tests can swap in a stub without touching the network.
  """

  @callback list_prices(map()) :: {:ok, %{data: list()}} | {:error, term()}
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback create_billing_portal_session(map()) :: {:ok, map()} | {:error, term()}
end
