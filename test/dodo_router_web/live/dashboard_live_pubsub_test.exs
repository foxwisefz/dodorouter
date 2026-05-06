defmodule DodoRouterWeb.DashboardLivePubSubTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.Logs

  setup :register_and_log_in_user

  describe "live updates" do
    test "dashboard refreshes stats periodically", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      # Create initial log
      {:ok, _log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          final_provider: "test",
          final_model: "test-model",
          total_tokens: 100
        })

      {:ok, live, html} = live(conn, ~p"/dashboard")
      assert html =~ "Total Requests"

      # Send refresh message (simulating the timer)
      send(live.pid, :refresh)

      # Should still render without error
      assert render(live) =~ "Router Overview"
    end
  end
end
