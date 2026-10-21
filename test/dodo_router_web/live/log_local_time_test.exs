defmodule DodoRouterWeb.LogLocalTimeTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.{LogsFixtures, Recordings, RoutersFixtures}

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, _} = RoutersFixtures.router_fixture(user)
    {:ok, recording} = Recordings.start_recording(router, %{name: "Local times"})

    log =
      LogsFixtures.log_fixture(router, %{
        session_id: "local-time-session",
        recording_id: recording.id,
        request_body: Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "Hi"}]})
      })

    %{router: router, recording: recording, log: log}
  end

  for surface <- [:router, :requests, :dashboard, :session, :recording] do
    @surface surface
    test "#{surface} logs carry an unambiguous instant for browser-local display", context do
      %{conn: conn, log: log} = context
      {:ok, view, _} = live(conn, page_path(@surface, context))

      selector = time_selector(@surface, log.id)
      iso8601 = DateTime.to_iso8601(log.inserted_at)

      assert has_element?(
               view,
               "time#{selector}[datetime='#{iso8601}'][data-utc='#{iso8601}'][phx-hook='LocalTime'][phx-update='ignore']"
             )

      # Until JavaScript connects, UTC must be identified rather than looking local.
      assert has_element?(view, selector, "UTC")
      assert has_element?(view, "#{selector}[data-fallback*='UTC']")
    end
  end

  test "replay comparisons localize both source and candidate dates", %{
    conn: conn,
    router: router,
    log: source
  } do
    candidate = LogsFixtures.log_fixture(router, %{replayed_from_id: source.id})
    {:ok, view, _} = live(conn, ~p"/logs/#{source.id}/replay")

    for log <- [source, candidate] do
      assert has_element?(
               view,
               "#log-time-#{log.id}[data-utc='#{DateTime.to_iso8601(log.inserted_at)}'][data-format='datetime'][phx-hook='LocalTime']"
             )
    end
  end

  for surface <- [:router, :requests] do
    @surface surface
    test "#{surface} timestamps have unique IDs when an existing log is delivered again",
         context do
      {:ok, view, _} = live(context.conn, page_path(@surface, context))
      send(view.pid, {:log_created, context.log})

      prefix = if @surface == :router, do: "recent_logs", else: "logs"
      assert has_element?(view, "##{prefix}-#{context.log.id}-time")
      assert has_element?(view, "##{prefix}-#{context.log.request_id}-time")
    end

    test "#{surface} live rows retain their time hook from pending through completion", context do
      %{conn: conn, router: router} = context
      {:ok, view, _} = live(conn, page_path(@surface, context))
      request_id = Ecto.UUID.generate()
      started_at = ~U[2026-10-21 22:59:59.000000Z]
      selector = time_selector(@surface, request_id)

      send(view.pid, {
        :log_pending,
        %{
          request_id: request_id,
          inserted_at: started_at,
          status: "pending",
          call_type: nil,
          final_provider: "test_provider",
          final_model: "test-model",
          latency_ms: nil,
          total_tokens: nil
        }
      })

      assert has_element?(
               view,
               "#{selector}[phx-hook='LocalTime'][data-utc='#{DateTime.to_iso8601(started_at)}']"
             )

      log =
        LogsFixtures.log_fixture(router, %{
          request_id: request_id,
          inserted_at: DateTime.add(started_at, 2)
        })

      send(view.pid, {:log_created, log})

      assert has_element?(
               view,
               "#{selector}[phx-hook='LocalTime'][data-utc='#{DateTime.to_iso8601(log.inserted_at)}']"
             )
    end
  end

  defp time_selector(:router, id), do: "#recent_logs-#{id}-time"
  defp time_selector(:requests, id), do: "#logs-#{id}-time"
  defp time_selector(_surface, id), do: "#log-time-#{id}"

  defp page_path(:router, %{router: router}), do: ~p"/routers/#{router.id}"
  defp page_path(:requests, %{router: router}), do: ~p"/logs?router_id=#{router.id}"
  defp page_path(:dashboard, %{router: router}), do: ~p"/dashboard?router_id=#{router.id}"

  defp page_path(:session, %{router: router}),
    do: ~p"/routers/#{router.id}/sessions/local-time-session"

  defp page_path(:recording, %{router: router, recording: recording}),
    do: ~p"/routers/#{router.id}/recordings/#{recording.id}"
end
