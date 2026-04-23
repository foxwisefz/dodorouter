defmodule DodoRouterWeb.LogLivePubSubTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.Logs

  setup :register_and_log_in_user

  describe "live updates" do
    test "receives new log via PubSub", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/logs?router_id=#{router.id}")

      # Create a log - this broadcasts to subscribers
      {:ok, _log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          final_provider: "live-test-provider",
          final_model: "test-model"
        })

      # LiveView should receive the broadcast and update
      assert render(live) =~ "live-test-provider"
    end

    test "shows pending log then completed log", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/logs?router_id=#{router.id}")

      request_id = Ecto.UUID.generate()

      # Send pending notification with required fields
      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router.id}:logs",
        {:log_pending,
         %{
           request_id: request_id,
           status: "pending",
           inserted_at: DateTime.utc_now(),
           final_provider: nil,
           final_model: nil,
           latency_ms: nil,
           total_tokens: nil,
           attempted_steps: []
         }}
      )

      html = render(live)
      assert html =~ "pending"

      # Now send completed log
      {:ok, _log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: request_id,
          status: "success",
          final_provider: "completed-provider",
          final_model: "test-model"
        })

      html = render(live)
      assert html =~ "success"
      assert html =~ "completed-provider"
    end
  end
end
