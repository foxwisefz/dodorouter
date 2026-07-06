defmodule DodoRouterWeb.StripeWebhookHandler do
  @moduledoc """
  Applies Stripe webhook events to local billing state.

  Mounted via `Stripe.WebhookPlug` in the endpoint (before `Plug.Parsers`,
  which would otherwise consume the raw body needed for signature
  verification). Handlers are idempotent — they mirror the event's current
  object state, so replays and out-of-order deliveries are harmless.

  Unknown users are acknowledged (not errored): Stripe retries would not fix
  them, and erroring keeps the event in Stripe's retry queue for days.
  """

  @behaviour Stripe.WebhookHandler

  require Logger

  alias DodoRouter.Billing

  @impl true
  def handle_event(%Stripe.Event{type: "checkout.session.completed", data: %{object: session}}) do
    if Billing.enabled?() do
      case Billing.handle_checkout_completed(session) do
        {:ok, _user} ->
          :ok

        {:error, reason} ->
          Logger.warning("stripe checkout.session.completed not applied: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  def handle_event(%Stripe.Event{
        type: "customer.subscription." <> _,
        data: %{object: subscription}
      }) do
    if Billing.enabled?() do
      case Billing.sync_subscription(subscription) do
        {:ok, _user} ->
          :ok

        {:error, reason} ->
          Logger.warning("stripe subscription event not applied: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  def handle_event(_event), do: :ok
end
