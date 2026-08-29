defmodule DodoRouterWeb.StripeWebhookTest do
  use DodoRouterWeb.ConnCase, async: false

  import DodoRouter.AccountsFixtures

  alias DodoRouter.Repo

  @webhook_secret "whsec_test_secret"
  @path "/webhooks/stripe"

  defp sign(payload, secret \\ @webhook_secret) do
    timestamp = System.os_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp post_event(conn, payload, signature) do
    conn
    |> put_req_header("stripe-signature", signature)
    |> put_req_header("content-type", "application/json")
    |> post(@path, payload)
  end

  defp event_payload(type, object) do
    Jason.encode!(%{
      id: "evt_#{System.unique_integer([:positive])}",
      object: "event",
      api_version: "2024-04-10",
      created: System.os_time(:second),
      type: type,
      data: %{object: object}
    })
  end

  test "rejects an invalid signature", %{conn: conn} do
    payload = event_payload("customer.subscription.updated", %{object: "subscription"})
    conn = post_event(conn, payload, sign(payload, "whsec_wrong"))
    assert conn.status == 400
  end

  test "checkout.session.completed links the user to the customer", %{conn: conn} do
    user = user_fixture()

    payload =
      event_payload("checkout.session.completed", %{
        object: "checkout.session",
        id: "cs_live_1",
        client_reference_id: user.id,
        customer: "cus_hook",
        subscription: "sub_hook"
      })

    conn = post_event(conn, payload, sign(payload))
    assert conn.status == 200

    user = Repo.reload!(user)
    assert user.stripe_customer_id == "cus_hook"
    assert user.stripe_subscription_id == "sub_hook"
  end

  test "customer.subscription.updated syncs status and period end", %{conn: conn} do
    user =
      user_fixture()
      |> Ecto.Changeset.change(stripe_customer_id: "cus_hook2")
      |> Repo.update!()

    period_end = System.os_time(:second) + 3600

    payload =
      event_payload("customer.subscription.updated", %{
        object: "subscription",
        id: "sub_hook2",
        status: "active",
        customer: "cus_hook2",
        current_period_end: period_end,
        metadata: %{}
      })

    conn = post_event(conn, payload, sign(payload))
    assert conn.status == 200

    user = Repo.reload!(user)
    assert user.subscription_status == "active"
    assert user.stripe_subscription_id == "sub_hook2"
    assert DateTime.to_unix(user.subscription_current_period_end) == period_end
  end

  test "customer.subscription.deleted marks the subscription canceled", %{conn: conn} do
    user =
      user_fixture()
      |> Ecto.Changeset.change(stripe_customer_id: "cus_hook3", subscription_status: "active")
      |> Repo.update!()

    payload =
      event_payload("customer.subscription.deleted", %{
        object: "subscription",
        id: "sub_hook3",
        status: "canceled",
        customer: "cus_hook3",
        current_period_end: nil,
        metadata: %{}
      })

    conn = post_event(conn, payload, sign(payload))
    assert conn.status == 200

    assert Repo.reload!(user).subscription_status == "canceled"
  end

  test "unhandled event types are acknowledged", %{conn: conn} do
    payload = event_payload("invoice.finalized", %{object: "invoice", id: "in_1"})
    conn = post_event(conn, payload, sign(payload))
    assert conn.status == 200
  end

  test "events for unknown users are acknowledged without changes", %{conn: conn} do
    payload =
      event_payload("customer.subscription.updated", %{
        object: "subscription",
        id: "sub_ghost",
        status: "active",
        customer: "cus_ghost",
        current_period_end: nil,
        metadata: %{}
      })

    conn = post_event(conn, payload, sign(payload))
    assert conn.status == 200
  end
end
