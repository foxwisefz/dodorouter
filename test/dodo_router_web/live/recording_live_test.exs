defmodule DodoRouterWeb.RecordingLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.Recordings

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, api_key} = RoutersFixtures.router_fixture(user)
    %{router: router, api_key: api_key}
  end

  describe "Index" do
    test "lists recordings for router", %{conn: conn, router: router} do
      {:ok, recording} = Recordings.start_recording(router, %{name: "Test Recording"})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/recordings")

      assert html =~ "Recordings"
      assert html =~ "Test Recording"
      assert html =~ recording.status
    end

    test "shows empty state when no recordings", %{conn: conn, router: router} do
      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/recordings")

      assert html =~ "No recordings yet"
      assert html =~ "Start Recording"
    end

    test "can start and stop recording from UI", %{conn: conn, router: router} do
      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/recordings")

      # Open the start form
      html = live |> element("button", "Start Recording") |> render_click()
      assert html =~ "Recording Name"

      # Start a recording
      html = live |> form("form", recording: %{name: "UI Test"}) |> render_submit()
      assert html =~ "Recording in progress"
      assert html =~ "UI Test"
      assert html =~ "Stop Recording"

      # Stop the recording
      html = live |> element("button", "Stop Recording") |> render_click()
      refute html =~ "Recording in progress"
      assert html =~ "stopped"
    end

    test "shows recording status badge", %{conn: conn, router: router} do
      {:ok, _} = Recordings.start_recording(router, %{name: "Active"})

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/recordings")

      assert html =~ "recording"
    end

    test "shows stopped recording", %{conn: conn, router: router} do
      {:ok, _} = Recordings.start_recording(router, %{name: "Stopped"})
      {:ok, _} = Recordings.stop_recording(router)

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/recordings")

      assert html =~ "stopped"
    end

    test "raises when router doesn't belong to user", %{conn: conn} do
      {other_router, _} = RoutersFixtures.router_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/routers/#{other_router.id}/recordings")
      end
    end
  end

  describe "Show" do
    test "latency stat shows p95 with p50 subtext, not a bare mean", %{
      conn: conn,
      router: router
    } do
      {:ok, recording} = Recordings.start_recording(router, %{name: "Latency Recording"})

      for _ <- 1..20 do
        DodoRouter.LogsFixtures.log_fixture(router, %{
          recording_id: recording.id,
          latency_ms: 100
        })
      end

      DodoRouter.LogsFixtures.log_fixture(router, %{
        recording_id: recording.id,
        latency_ms: 10_000
      })

      {:ok, _live, html} = live(conn, ~p"/routers/#{router.id}/recordings/#{recording.id}")

      assert html =~ "p95 Latency"
      refute html =~ "Avg Latency"
    end

    test "offers benchmarking once something is captured", %{conn: conn, router: router} do
      {:ok, recording} = Recordings.start_recording(router, %{name: "Capture"})

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/recordings/#{recording.id}")
      refute has_element?(live, "#benchmark-recording-button")

      DodoRouter.LogsFixtures.log_fixture(router, %{recording_id: recording.id})

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/recordings/#{recording.id}")

      assert has_element?(
               live,
               "#benchmark-recording-button[href='/routers/#{router.id}/recordings/#{recording.id}/evals/new']"
             )
    end

    test "lists the benchmarks measured on this capture", %{
      conn: conn,
      router: router,
      user: user
    } do
      provider_key = DodoRouter.ProvidersFixtures.provider_key_fixture(user)
      {:ok, recording} = Recordings.start_recording(router, %{name: "Capture"})
      log = DodoRouter.LogsFixtures.log_fixture(router, %{recording_id: recording.id})

      {:ok, evaluation} =
        DodoRouter.Evaluations.create_evaluation(user, log, %{
          name: "Downgrade check",
          criteria: "Answer accurately",
          judge_model: "test-model",
          judge_provider_key_id: provider_key.id,
          candidate_targets: [
            %{
              "provider_key_id" => provider_key.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ],
          recording_id: recording.id
        })

      {:ok, live, _html} = live(conn, ~p"/routers/#{router.id}/recordings/#{recording.id}")

      assert has_element?(live, "#recording-benchmarks", "Downgrade check")
      assert has_element?(live, "#recording-benchmarks a[href='/evals/#{evaluation.id}']")
    end
  end
end
