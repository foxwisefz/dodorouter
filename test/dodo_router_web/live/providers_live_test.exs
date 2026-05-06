defmodule DodoRouterWeb.ProvidersLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias DodoRouter.Repo
  alias DodoRouter.Providers.ProviderKey

  setup :register_and_log_in_user

  describe "Index" do
    test "shows providers page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/providers")

      assert html =~ "Providers"
      assert html =~ "Connect your LLM provider API keys"
    end

    test "shows all provider cards", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/providers")

      assert html =~ "z.ai Standard"
      assert html =~ "z.ai Coding"
      assert html =~ "Moonshot"
      assert html =~ "Moonshot Coding"
      assert html =~ "OpenAI"
      assert html =~ "Anthropic"
      assert html =~ "Google"
      assert html =~ "Groq"
      assert html =~ "Mistral"
      assert html =~ "xAI"
      assert html =~ "DeepSeek"
      assert html =~ "Cohere"
    end

    test "shows key_hint next to key label", %{conn: conn, user: user} do
      %ProviderKey{}
      |> ProviderKey.create_changeset(
        %{"provider_slug" => "zai_standard"},
        user.id,
        "sk-•••••••xyz"
      )
      |> Repo.insert!()

      {:ok, _live, html} = live(conn, ~p"/providers")

      assert html =~ "sk-•••••••xyz"
    end

    test "can open add key form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      html =
        live
        |> element("button[phx-click=\"start_add\"][phx-value-provider=\"zai_standard\"]")
        |> render_click()

      assert html =~ "Paste your API key here"
      assert html =~ "Save"
      assert html =~ "Cancel"
    end

    test "can cancel add key form", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      live
      |> element("button[phx-click=\"start_add\"][phx-value-provider=\"zai_standard\"]")
      |> render_click()

      html =
        live
        |> element("button[phx-click=\"cancel_add\"]")
        |> render_click()

      refute html =~ "Paste your API key here"
    end

    test "form stays open when submitting empty key", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      live
      |> element("button[phx-click=\"start_add\"][phx-value-provider=\"zai_standard\"]")
      |> render_click()

      live
      |> form("form", provider_key: %{api_key: ""})
      |> render_submit()

      # Form should still be visible after empty submission
      assert has_element?(live, "input[name=\"provider_key[api_key]\"]")
    end
  end
end
