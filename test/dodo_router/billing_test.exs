defmodule DodoRouter.BillingTest do
  use DodoRouter.DataCase, async: false

  import DodoRouter.AccountsFixtures

  alias DodoRouter.Billing
  alias DodoRouter.Repo

  defp set_billing(user, attrs) do
    user |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  describe "subscribed?/1" do
    test "active, trialing and past_due count as subscribed" do
      for status <- ["active", "trialing", "past_due"] do
        user = user_fixture() |> set_billing(subscription_status: status)
        assert Billing.subscribed?(user), "expected #{status} to be subscribed"
      end
    end

    test "nil and terminal statuses are not subscribed" do
      for status <- [nil, "canceled", "unpaid", "incomplete", "incomplete_expired"] do
        user = user_fixture() |> set_billing(subscription_status: status)
        refute Billing.subscribed?(user), "expected #{inspect(status)} to not be subscribed"
      end
    end

    test "everyone passes when billing is disabled" do
      original = Application.get_env(:dodo_router, :billing)
      Application.put_env(:dodo_router, :billing, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:dodo_router, :billing, original) end)

      refute Billing.enabled?()
      assert Billing.subscribed?(user_fixture())
    end
  end

  describe "create_checkout_session/2" do
    test "new customer: passes email, price from lookup key and user reference" do
      user = user_fixture()

      assert {:ok, %{url: "https://checkout.stripe.com/" <> _}} =
               Billing.create_checkout_session(user, "https://example.com")

      assert_received {:stripe_stub, {:list_prices, %{lookup_keys: [lookup_key]}}}
      assert lookup_key == "dodo_router_monthly_19"

      assert_received {:stripe_stub, {:create_checkout_session, params}}
      assert params.mode == "subscription"
      assert params.customer_email == user.email
      refute Map.has_key?(params, :customer)
      assert params.client_reference_id == user.id
      assert [%{price: "price_stub_19", quantity: 1}] = params.line_items
      assert params.success_url == "https://example.com/billing?checkout=success"
      assert params.cancel_url == "https://example.com/billing?checkout=canceled"
      assert params.subscription_data.metadata["user_id"] == user.id
      refute Map.has_key?(params.subscription_data, :trial_period_days)
    end

    test "existing customer: reuses the stripe customer id" do
      user = user_fixture() |> set_billing(stripe_customer_id: "cus_123")

      assert {:ok, _} = Billing.create_checkout_session(user, "https://example.com")

      assert_received {:stripe_stub, {:create_checkout_session, params}}
      assert params.customer == "cus_123"
      refute Map.has_key?(params, :customer_email)
    end

    test "configured trial days are passed to the subscription" do
      original = Application.get_env(:dodo_router, :billing)
      Application.put_env(:dodo_router, :billing, Keyword.put(original, :trial_days, 14))
      on_exit(fn -> Application.put_env(:dodo_router, :billing, original) end)

      assert {:ok, _} = Billing.create_checkout_session(user_fixture(), "https://example.com")

      assert_received {:stripe_stub, {:create_checkout_session, params}}
      assert params.subscription_data.trial_period_days == 14
    end

    test "returns an error when the price is missing in Stripe" do
      Process.put({:stripe_stub, :list_prices}, {:ok, %{data: []}})

      assert {:error, :price_not_found} =
               Billing.create_checkout_session(user_fixture(), "https://example.com")
    end
  end

  describe "create_portal_session/2" do
    test "requires a linked stripe customer" do
      assert {:error, :no_customer} =
               Billing.create_portal_session(user_fixture(), "https://example.com")
    end

    test "creates a portal session for the customer" do
      user = user_fixture() |> set_billing(stripe_customer_id: "cus_123")

      assert {:ok, %{url: "https://billing.stripe.com/" <> _}} =
               Billing.create_portal_session(user, "https://example.com")

      assert_received {:stripe_stub, {:create_billing_portal_session, params}}
      assert params.customer == "cus_123"
      assert params.return_url == "https://example.com/billing"
    end
  end

  describe "handle_checkout_completed/1" do
    test "links customer and subscription ids to the referenced user" do
      user = user_fixture()

      session = %{
        client_reference_id: user.id,
        customer: "cus_abc",
        subscription: "sub_abc"
      }

      assert {:ok, updated} = Billing.handle_checkout_completed(session)
      assert updated.stripe_customer_id == "cus_abc"
      assert updated.stripe_subscription_id == "sub_abc"
    end

    test "unknown or invalid user reference is reported" do
      session = %{
        client_reference_id: Ecto.UUID.generate(),
        customer: "cus_x",
        subscription: "sub_x"
      }

      assert {:error, :user_not_found} = Billing.handle_checkout_completed(session)

      session = %{client_reference_id: "not-a-uuid", customer: "cus_x", subscription: "sub_x"}
      assert {:error, :user_not_found} = Billing.handle_checkout_completed(session)
    end
  end

  describe "sync_subscription/1" do
    test "updates the user found by stripe customer id" do
      user = user_fixture() |> set_billing(stripe_customer_id: "cus_sync")
      period_end = System.os_time(:second) + 30 * 24 * 3600

      subscription = %{
        id: "sub_sync",
        status: "active",
        customer: "cus_sync",
        current_period_end: period_end,
        metadata: %{}
      }

      assert {:ok, updated} = Billing.sync_subscription(subscription)
      assert updated.id == user.id
      assert updated.subscription_status == "active"
      assert updated.stripe_subscription_id == "sub_sync"
      assert DateTime.to_unix(updated.subscription_current_period_end) == period_end
    end

    test "falls back to the user_id metadata when the customer is not linked yet" do
      user = user_fixture()

      subscription = %{
        id: "sub_meta",
        status: "trialing",
        customer: "cus_meta",
        current_period_end: nil,
        metadata: %{"user_id" => user.id}
      }

      assert {:ok, updated} = Billing.sync_subscription(subscription)
      assert updated.id == user.id
      assert updated.stripe_customer_id == "cus_meta"
      assert updated.subscription_status == "trialing"
      assert updated.subscription_current_period_end == nil
    end

    test "cancellation flips the status" do
      user =
        user_fixture()
        |> set_billing(stripe_customer_id: "cus_bye", subscription_status: "active")

      subscription = %{
        id: "sub_bye",
        status: "canceled",
        customer: "cus_bye",
        current_period_end: nil,
        metadata: %{}
      }

      assert {:ok, updated} = Billing.sync_subscription(subscription)
      assert updated.subscription_status == "canceled"
      refute Billing.subscribed?(updated)
      assert updated.id == user.id
    end

    test "unknown customer is reported" do
      subscription = %{
        id: "s",
        status: "active",
        customer: "cus_ghost",
        current_period_end: nil,
        metadata: %{}
      }

      assert {:error, :user_not_found} = Billing.sync_subscription(subscription)
    end
  end
end
