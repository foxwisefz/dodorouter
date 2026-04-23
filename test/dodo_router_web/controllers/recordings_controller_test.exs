defmodule DodoRouterWeb.RecordingsControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.RoutersFixtures
  alias DodoRouter.Recordings

  setup do
    {router, api_key} = RoutersFixtures.router_fixture()
    %{router: router, api_key: api_key}
  end

  defp auth_conn(conn, api_key) do
    put_req_header(conn, "authorization", "Bearer #{api_key}")
  end

  describe "POST /r/:router_slug/recordings/start" do
    test "starts a recording with a name", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> auth_conn(api_key)
        |> post("/r/#{router.slug}/recordings/start", %{"name" => "Test Recording"})

      assert %{
               "id" => _id,
               "name" => "Test Recording",
               "status" => "recording",
               "started_at" => _,
               "stopped_at" => nil
             } = json_response(conn, 201)
    end

    test "starts a recording without a name", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> auth_conn(api_key)
        |> post("/r/#{router.slug}/recordings/start", %{})

      assert %{
               "id" => _,
               "name" => nil,
               "status" => "recording"
             } = json_response(conn, 201)
    end

    test "stops existing recording when starting a new one", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn
      |> auth_conn(api_key)
      |> post("/r/#{router.slug}/recordings/start", %{"name" => "First"})

      conn =
        build_conn()
        |> auth_conn(api_key)
        |> post("/r/#{router.slug}/recordings/start", %{"name" => "Second"})

      assert %{"name" => "Second", "status" => "recording"} = json_response(conn, 201)

      recordings = Recordings.list_recordings(router)
      assert length(recordings) == 2
      assert Enum.count(recordings, &(&1.status == "recording")) == 1
      assert Enum.count(recordings, &(&1.status == "stopped")) == 1
    end

    test "returns 401 without auth", %{conn: conn, router: router} do
      conn = post(conn, "/r/#{router.slug}/recordings/start", %{})
      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "returns 401 with wrong api key", %{conn: conn, router: router} do
      conn =
        conn
        |> auth_conn("sk-dodo-invalid")
        |> post("/r/#{router.slug}/recordings/start", %{})

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end

    test "returns 401 when slug doesn't match api key", %{conn: conn, api_key: api_key} do
      {other_router, _} = RoutersFixtures.router_fixture()

      conn =
        conn
        |> auth_conn(api_key)
        |> post("/r/#{other_router.slug}/recordings/start", %{})

      assert json_response(conn, 401)["error"]["type"] == "authentication_error"
    end
  end

  describe "GET /r/:router_slug/recordings/active" do
    test "returns active recording", %{conn: conn, router: router, api_key: api_key} do
      {:ok, recording} = Recordings.start_recording(router, %{name: "Active"})

      conn =
        conn
        |> auth_conn(api_key)
        |> get("/r/#{router.slug}/recordings/active")

      assert %{
               "id" => id,
               "name" => "Active",
               "status" => "recording"
             } = json_response(conn, 200)

      assert id == recording.id
    end

    test "returns 404 when no active recording", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> auth_conn(api_key)
        |> get("/r/#{router.slug}/recordings/active")

      assert %{"error" => %{"message" => "No active recording", "type" => "not_found"}} =
               json_response(conn, 404)
    end

    test "returns 404 when recording is stopped", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      {:ok, _recording} = Recordings.start_recording(router, %{name: "Stopped"})
      {:ok, _} = Recordings.stop_recording(router)

      conn =
        conn
        |> auth_conn(api_key)
        |> get("/r/#{router.slug}/recordings/active")

      assert json_response(conn, 404)["error"]["type"] == "not_found"
    end
  end

  describe "POST /r/:router_slug/recordings/active/stop" do
    test "stops active recording", %{conn: conn, router: router, api_key: api_key} do
      {:ok, recording} = Recordings.start_recording(router, %{name: "To Stop"})

      conn =
        conn
        |> auth_conn(api_key)
        |> post("/r/#{router.slug}/recordings/active/stop")

      response = json_response(conn, 200)
      assert response["id"] == recording.id
      assert response["status"] == "stopped"
      assert response["stopped_at"] != nil
    end

    test "returns 404 when no active recording", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn
        |> auth_conn(api_key)
        |> post("/r/#{router.slug}/recordings/active/stop")

      assert %{"error" => %{"message" => "No active recording", "type" => "not_found"}} =
               json_response(conn, 404)
    end
  end
end
