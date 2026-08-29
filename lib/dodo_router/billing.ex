defmodule DodoRouter.Billing do
  @moduledoc """
  Stripe-backed subscription billing.

  Users subscribe to a single monthly plan via Stripe Checkout; the local
  billing fields on `users` are a mirror of Stripe state, kept in sync by the
  webhook handler (`DodoRouterWeb.StripeWebhookHandler`). Stripe is the source
  of truth — nothing here mutates subscriptions directly.

  Billing is disabled unless `STRIPE_SECRET_KEY` is set (see
  `config/runtime.exs`); while disabled, `subscribed?/1` passes everyone.
  """

  alias DodoRouter.Accounts.User
  alias DodoRouter.Repo

  # past_due keeps access while Stripe retries the card
  @paid_statuses ~w(active trialing past_due)

  def enabled?, do: Keyword.get(config(), :enabled, false)

  def webhook_secret, do: Keyword.get(config(), :webhook_secret) || ""

  def price_lookup_key, do: Keyword.fetch!(config(), :price_lookup_key)

  def trial_days, do: Keyword.get(config(), :trial_days, 0)

  @doc """
  Whether the user has access to paid functionality.

  Always true when billing is disabled (e.g. dev without Stripe keys).
  """
  def subscribed?(%User{} = user) do
    not enabled?() or user.subscription_status in @paid_statuses
  end

  @doc """
  Creates a Stripe Checkout session for the $19/month subscription.

  `base_url` is the externally visible origin (e.g. from `Endpoint.url/0`)
  used to build the success/cancel return URLs.
  """
  def create_checkout_session(%User{} = user, base_url) do
    with {:ok, price_id} <- fetch_price_id() do
      %{
        mode: "subscription",
        line_items: [%{price: price_id, quantity: 1}],
        client_reference_id: user.id,
        success_url: base_url <> "/billing?checkout=success",
        cancel_url: base_url <> "/billing?checkout=canceled",
        subscription_data: subscription_data(user),
        allow_promotion_codes: true
      }
      |> put_customer(user)
      |> stripe_client().create_checkout_session()
    end
  end

  @doc """
  Creates a Stripe Billing Portal session so the user can manage their
  subscription (card, cancellation, invoices).
  """
  def create_portal_session(%User{stripe_customer_id: nil}, _base_url), do: {:error, :no_customer}

  def create_portal_session(%User{} = user, base_url) do
    stripe_client().create_billing_portal_session(%{
      customer: user.stripe_customer_id,
      return_url: base_url <> "/billing"
    })
  end

  @doc """
  Applies a `checkout.session.completed` webhook: links the Stripe customer
  and subscription to the user referenced by `client_reference_id`.
  """
  def handle_checkout_completed(session) do
    with {:ok, user_id} <- Ecto.UUID.cast(session.client_reference_id || ""),
         %User{} = user <- Repo.get(User, user_id) do
      user
      |> Ecto.Changeset.change(
        stripe_customer_id: stripe_id(session.customer),
        stripe_subscription_id: stripe_id(session.subscription)
      )
      |> Repo.update()
    else
      _ -> {:error, :user_not_found}
    end
  end

  @doc """
  Applies a `customer.subscription.*` webhook: mirrors the subscription's
  status and period end onto the owning user.

  The user is found by the linked `stripe_customer_id`, falling back to the
  `user_id` metadata we set at checkout (covers the race where subscription
  events arrive before `checkout.session.completed`).
  """
  def sync_subscription(subscription) do
    customer_id = stripe_id(subscription.customer)

    case find_user(customer_id, subscription.metadata) do
      %User{} = user ->
        user
        |> Ecto.Changeset.change(
          stripe_customer_id: customer_id,
          stripe_subscription_id: subscription.id,
          subscription_status: subscription.status,
          subscription_current_period_end: period_end(subscription)
        )
        |> Repo.update()

      nil ->
        {:error, :user_not_found}
    end
  end

  defp find_user(customer_id, metadata) do
    Repo.get_by(User, stripe_customer_id: customer_id) || find_user_by_metadata(metadata)
  end

  defp find_user_by_metadata(%{"user_id" => user_id}) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> Repo.get(User, id)
      :error -> nil
    end
  end

  defp find_user_by_metadata(_), do: nil

  # Older Stripe API versions report the period end on the subscription;
  # newer ones only on its items.
  defp period_end(%{current_period_end: ts}) when is_integer(ts), do: DateTime.from_unix!(ts)

  defp period_end(%{items: %{data: [%{current_period_end: ts} | _]}}) when is_integer(ts),
    do: DateTime.from_unix!(ts)

  defp period_end(_), do: nil

  defp subscription_data(user) do
    data = %{metadata: %{"user_id" => user.id}}

    case trial_days() do
      days when is_integer(days) and days > 0 -> Map.put(data, :trial_period_days, days)
      _ -> data
    end
  end

  defp put_customer(params, %User{stripe_customer_id: nil} = user),
    do: Map.put(params, :customer_email, user.email)

  defp put_customer(params, %User{stripe_customer_id: customer_id}),
    do: Map.put(params, :customer, customer_id)

  defp fetch_price_id do
    case stripe_client().list_prices(%{lookup_keys: [price_lookup_key()], active: true}) do
      {:ok, %{data: [%{id: price_id} | _]}} -> {:ok, price_id}
      {:ok, %{data: []}} -> {:error, :price_not_found}
      {:error, error} -> {:error, error}
    end
  end

  # Stripe sends either a bare id or an expanded object depending on the event
  defp stripe_id(nil), do: nil
  defp stripe_id(id) when is_binary(id), do: id
  defp stripe_id(%{id: id}), do: id

  defp stripe_client, do: Application.fetch_env!(:dodo_router, :stripe_client)

  defp config, do: Application.fetch_env!(:dodo_router, :billing)
end
