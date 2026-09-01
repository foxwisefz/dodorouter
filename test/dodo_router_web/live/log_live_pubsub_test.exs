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

    test "a pending row moves to the backup step when a fallback fires", %{
      conn: conn,
      user: user
    } do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/logs?router_id=#{router.id}")

      request_id = Ecto.UUID.generate()

      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router.id}:logs",
        {:log_pending,
         %{
           request_id: request_id,
           status: "pending",
           inserted_at: DateTime.utc_now(),
           final_provider: "anthropic",
           final_model: "claude-opus-4-8",
           latency_ms: nil,
           total_tokens: nil,
           attempted_steps: [%{"provider" => "anthropic", "model" => "claude-opus-4-8"}]
         }}
      )

      assert render(live) =~ "claude-opus-4-8"

      # FallbackChain broadcasts this when it starts a step past the first —
      # the row must show the backup actually serving, not the dead provider.
      Phoenix.PubSub.broadcast(
        DodoRouter.PubSub,
        "router:#{router.id}:logs",
        {:log_pending_update,
         %{
           router_id: router.id,
           request_id: request_id,
           provider: "moonshot",
           model: "kimi-k2.6",
           plan_type: "coding",
           step_index: 1,
           timestamp: DateTime.utc_now()
         }}
      )

      html = render(live)
      # The hop chain shows both providers, and the model line names the
      # backup now serving instead of the provider that died.
      assert html =~ "moonshot"
      assert html =~ "anthropic"
      assert html =~ "kimi-k2.6"
      refute html =~ "claude-opus-4-8"
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
