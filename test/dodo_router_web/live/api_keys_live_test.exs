defmodule DodoRouterWeb.ApiKeysLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists routers with endpoint and a working copy button", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, html} = live(conn, ~p"/api-keys")

      assert html =~ router.name
      assert html =~ "/r/#{router.slug}/v1/chat/completions"

      # The copy button must use the CopyButton hook — JS.dispatch("phx:copy")
      # has no registered listener and silently does nothing.
      assert has_element?(live, "#copy-endpoint-#{router.id}[phx-hook=CopyButton]")
      refute render(live) =~ "phx:copy"
    end

    test "regenerating reveals the new key once with a copy button", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/api-keys")

      live |> element("#regenerate-#{router.id}") |> render_click()
      html = live |> element("#confirm-regenerate-#{router.id}") |> render_click()

      assert html =~ "New API Key Generated"
      assert has_element?(live, "#copy-new-api-key[phx-hook=CopyButton][data-copy]")
    end
  end
end
