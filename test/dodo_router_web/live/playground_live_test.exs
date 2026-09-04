defmodule DodoRouterWeb.PlaygroundLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Models
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Repo
  alias DodoRouter.RoutersFixtures

  # A 1×1 transparent PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    %{router: router, key: key}
  end

  # Two changes, as a person makes them: the key first, then the model —
  # a key switch clears the model field, so one combined change would too.
  defp pick_model(view, key, model) do
    view
    |> form("#playground-form", %{
      target: %{provider_key_id: key.id, model: "", reasoning_effort: ""}
    })
    |> render_change()

    view
    |> form("#playground-form", %{
      target: %{provider_key_id: key.id, model: model, reasoning_effort: ""}
    })
    |> render_change()
  end

  defp send_text(view, text) do
    view
    |> form("#playground-composer", %{composer: %{text: text}})
    |> render_submit()

    render_async(view)
  end

  defp playground_logs(router) do
    Repo.all(
      from l in RequestLog,
        where: l.router_id == ^router.id and l.traffic_type == "playground",
        order_by: [asc: l.inserted_at]
    )
  end

  describe "mount" do
    test "renders the picker, an empty thread and the composer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/playground")

      assert has_element?(view, "#playground-form")
      assert has_element?(view, "#playground-provider-key")
      assert has_element?(view, "#playground-model")
      assert has_element?(view, "#playground-empty-state")
      assert has_element?(view, "#playground-composer")
      assert has_element?(view, "#playground-send")
    end

    test "asks for a router when the user has none", %{conn: conn} do
      conn = log_in_user(conn, AccountsFixtures.user_fixture())
      {:ok, view, _html} = live(conn, ~p"/playground")

      assert has_element?(view, "#playground-no-router")
      refute has_element?(view, "#playground-composer")
    end

    test "asks for a provider key when the user has none", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      RoutersFixtures.router_fixture(user)
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/playground")

      assert has_element?(view, "#playground-no-keys")
      refute has_element?(view, "#playground-composer")
    end

    test "the router page links here", %{conn: conn, router: router} do
      {:ok, view, _html} = live(conn, ~p"/routers/#{router.id}")

      assert has_element?(view, "#router-playground-link")
    end

    test "the sidebar links here", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/playground")

      assert html =~ ~s(href="/playground")
    end
  end

  describe "picking a model" do
    test "shows what the catalog says the model supports", %{conn: conn, key: key} do
      {:ok, _model} =
        Models.upsert_model(%{
          provider_slug: "test_provider",
          model_id: "test-model",
          display_name: "Test Model",
          supports_vision: true,
          supports_function_calling: false,
          max_input_tokens: 128_000
        })

      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")

      assert has_element?(view, "#cap-vision[data-on=true]")
      assert has_element?(view, "#cap-tools[data-on=false]")
      assert render(view) =~ "128K ctx"
    end

    test "says so when the catalog does not know the model", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "made-up-model")

      assert render(view) =~ "Not in the catalog"
    end

    test "switching the provider key clears the model", %{conn: conn, user: user, key: key} do
      other = ProvidersFixtures.provider_key_fixture(user, %{label: "second key"})

      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")
      assert has_element?(view, ~s(#playground-model[value="test-model"]))

      # The browser re-sends the whole form on a key change, stale model and all
      view
      |> form("#playground-form", %{
        target: %{provider_key_id: other.id, model: "test-model", reasoning_effort: ""}
      })
      |> render_change()

      refute has_element?(view, ~s(#playground-model[value="test-model"]))
    end
  end

  describe "sending a turn" do
    test "streams the answer into the thread and files a playground log", %{
      conn: conn,
      key: key,
      router: router
    } do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")

      html = send_text(view, "hello there")

      assert html =~ "hello there"
      assert html =~ "Hello from test-model"
      assert has_element?(view, "[data-role=user]")
      assert has_element?(view, "[data-role=assistant][data-status=done]")
      refute has_element?(view, "#playground-empty-state")

      [log] = playground_logs(router)
      assert log.status == "success"
      assert log.final_model == "test-model"
      assert has_element?(view, ~s(.playground-log-link[href="/logs/#{log.id}"]))

      # The stored request is the thread as sent
      assert %{"messages" => [%{"role" => "user", "content" => "hello there"}]} =
               Jason.decode!(log.request_body)
    end

    test "the thread continues on the next turn, on whichever model is picked", %{
      conn: conn,
      key: key,
      router: router
    } do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")
      send_text(view, "first")

      pick_model(view, key, "alias-model")
      html = send_text(view, "second")

      # Each answer is labelled with the model that gave it
      assert html =~ "Hello from test-model"
      assert html =~ "Hello from alias-model"
      assert has_element?(view, "[data-role=assistant] .font-mono", "alias-model")

      [_first, second] = playground_logs(router)

      assert %{"messages" => messages} = Jason.decode!(second.request_body)

      assert Enum.map(messages, &{&1["role"], &1["content"]}) == [
               {"user", "first"},
               {"assistant", "Hello from test-model"},
               {"user", "second"}
             ]
    end

    test "a system prompt leads every turn", %{conn: conn, key: key, router: router} do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")

      view |> element("#playground-toggle-system") |> render_click()

      view
      |> form("#playground-system-form", %{system: %{prompt: "Answer in French."}})
      |> render_change()

      send_text(view, "bonjour?")

      [log] = playground_logs(router)

      assert %{"messages" => [%{"role" => "system", "content" => "Answer in French."} | _]} =
               Jason.decode!(log.request_body)
    end

    test "a provider failure shows in the thread with its log", %{
      conn: conn,
      key: key,
      router: router
    } do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "fail-model")

      html = send_text(view, "will this work?")

      assert has_element?(view, ".playground-turn-error")
      assert html =~ "Test Provider"

      [log] = playground_logs(router)
      assert log.status == "error"
      assert has_element?(view, ~s(.playground-log-link[href="/logs/#{log.id}"]))
    end

    test "a failed answer is not part of the history the next turn sends", %{
      conn: conn,
      key: key,
      router: router
    } do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "fail-model")
      send_text(view, "first")

      pick_model(view, key, "test-model")
      send_text(view, "second")

      [_failed, ok] = playground_logs(router)
      assert %{"messages" => messages} = Jason.decode!(ok.request_body)
      assert Enum.map(messages, & &1["role"]) == ["user", "user"]
    end

    test "asks for a model before sending", %{conn: conn, router: router} do
      {:ok, view, _html} = live(conn, ~p"/playground")

      html = send_text(view, "no model picked")

      assert has_element?(view, ".playground-turn-error")
      assert html =~ "Pick a model"
      assert playground_logs(router) == []
    end
  end

  describe "ask again" do
    test "re-sends the last question to the newly picked model", %{
      conn: conn,
      key: key,
      router: router
    } do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")
      send_text(view, "compare me")

      pick_model(view, key, "alias-model")
      view |> element("#playground-ask-again") |> render_click()
      html = render_async(view)

      # One user turn, one answer — the earlier answer was replaced
      assert html =~ "Hello from alias-model"
      refute html =~ "Hello from test-model"

      [_first, second] = playground_logs(router)

      assert %{"messages" => [%{"role" => "user", "content" => "compare me"}]} =
               Jason.decode!(second.request_body)
    end
  end

  describe "images" do
    test "an attached image travels with the turn as an image part", %{
      conn: conn,
      key: key,
      router: router
    } do
      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "test-model")

      view
      |> file_input("#playground-composer", :images, [
        %{name: "dot.png", content: @png, type: "image/png"}
      ])
      |> render_upload("dot.png")

      assert has_element?(view, "#playground-pending-images")

      html = send_text(view, "what is this?")

      assert html =~ "Hello from test-model"
      assert has_element?(view, "[data-role=user] img[alt='dot.png']")

      [log] = playground_logs(router)

      assert %{
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "text", "text" => "what is this?"},
                     %{
                       "type" => "image_url",
                       "image_url" => %{"url" => "data:image/png;base64," <> _}
                     }
                   ]
                 }
               ]
             } = Jason.decode!(log.request_body)

      # ...and reached the provider as one, rather than flattened into text
      [attempt] = log.attempted_steps

      assert %{"messages" => [%{"content" => [_text, %{"type" => "image_url"}]}]} =
               Jason.decode!(attempt["outbound_body"])
    end

    test "warns when the catalog says the model takes no images", %{conn: conn, key: key} do
      {:ok, _model} =
        Models.upsert_model(%{
          provider_slug: "test_provider",
          model_id: "text-only-model",
          display_name: "Text Only",
          supports_vision: false
        })

      {:ok, view, _html} = live(conn, ~p"/playground")
      pick_model(view, key, "text-only-model")
      refute has_element?(view, "#playground-vision-warning")

      view
      |> file_input("#playground-composer", :images, [
        %{name: "dot.png", content: @png, type: "image/png"}
      ])
      |> render_upload("dot.png")

      assert has_element?(view, "#playground-vision-warning")
      assert render(view) =~ "Text Only"
    end
  end

  test "clearing the thread empties it", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, ~p"/playground")
    pick_model(view, key, "test-model")
    send_text(view, "bye")

    view |> element("#playground-clear") |> render_click()

    assert has_element?(view, "#playground-empty-state")
    refute has_element?(view, "[data-role=assistant]")
  end
end
