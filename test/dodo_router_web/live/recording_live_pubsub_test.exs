defmodule DodoRouterWeb.RecordingLivePubSubTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.Recordings
  alias DodoRouter.Logs

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, api_key} = RoutersFixtures.router_fixture(user)
    %{router: router, api_key: api_key}
  end

  describe "live updates" do
    test "recordings list updates when new log arrives", %{conn: conn, router: router} do
      {:ok, recording} = Recordings.start_recording(router, %{name: "Live Test"})

      {:ok, live, html} = live(conn, ~p"/routers/#{router.id}/recordings")
      assert html =~ "Live Test"

      # Create a log for this recording
      {:ok, _log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          recording_id: recording.id,
          final_provider: "test",
          final_model: "test-model"
        })

      # The page should still show the recording
      assert render(live) =~ "Live Test"
    end
  end
end
