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

      # old-scheme stored hints are compacted to fixed width at render

      assert html =~ "sk-••••xyz"
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

  test "shows a continue-setup banner when arriving from a router", %{conn: conn, user: user} do
    {router, _} = DodoRouter.RoutersFixtures.router_fixture(user)

    {:ok, live, _html} = live(conn, ~p"/providers?return_to=/routers/#{router.id}")

    assert has_element?(live, "#return-to-router")
    assert has_element?(live, "#return-to-router a[href='/routers/#{router.id}']")
  end

  test "ignores non-router return_to values", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/providers?return_to=https://evil.example")

    refute has_element?(live, "#return-to-router")
  end

  describe "errors reach the user" do
    # Every failure on this page was a put_flash that nothing rendered: the
    # template never wrapped itself in <Layouts.app>, which is the only place
    # flash_group lives. A save that failed at the secret store looked exactly
    # like a button that did nothing.
    test "a rejected save says why", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      live
      |> element("button[phx-click=\"start_add\"][phx-value-provider=\"zai_standard\"]")
      |> render_click()

      html =
        live
        |> form("form", provider_key: %{api_key: ""})
        |> render_submit()

      assert has_element?(live, "#flash-group")
      assert html =~ "Please enter an API key"
    end
  end

  describe "deleting a key that evaluations judge with" do
    setup %{user: user} do
      {router, _} = DodoRouter.RoutersFixtures.router_fixture(user)
      log = DodoRouter.LogsFixtures.log_fixture(router)

      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard",
          "label" => "Key 1"
        })

      {:ok, evaluation} =
        DodoRouter.Evaluations.create_evaluation(user, log, %{
          name: "Helpful answer",
          criteria: "Answer directly and accurately",
          judge_model: "glm-4.6",
          judge_provider_key_id: key.id,
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "zai_standard",
              "model" => "glm-4.6"
            }
          ],
          repetitions: 1
        })

      %{key: key, evaluation: evaluation}
    end

    test "says which evaluations hold the key", %{conn: conn, key: key} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      html =
        live
        |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
        |> render_click()

      # the row survives, and the page says what is holding it
      assert has_element?(live, "#key-#{key.id}")
      assert html =~ "1 evaluation"
      assert Repo.get(ProviderKey, key.id)
    end

    test "reassigns the judge to another key of the same provider, then deletes",
         %{conn: conn, user: user, key: key, evaluation: evaluation} do
      replacement =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard",
          "label" => "Key 2"
        })

      {:ok, live, _html} = live(conn, ~p"/providers")

      live
      |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
      |> render_click()

      # the replacement is offered by label
      assert has_element?(live, "#reassign-judge-#{key.id} option[value=\"#{replacement.id}\"]")

      live
      |> form("#reassign-judge-#{key.id}", %{"replacement_id" => replacement.id})
      |> render_submit()

      assert Repo.get(DodoRouter.Logs.Evaluation, evaluation.id).judge_provider_key_id ==
               replacement.id

      refute Repo.get(ProviderKey, key.id)
    end

    test "offers no reassignment when the provider has no other key", %{conn: conn, key: key} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      html =
        live
        |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
        |> render_click()

      refute has_element?(live, "#reassign-judge-#{key.id}")
      assert html =~ "Add another z.ai Standard key"
    end

    test "counts candidate references too, which no foreign key protects", %{
      conn: conn,
      user: user,
      key: key,
      evaluation: evaluation
    } do
      # A second evaluation uses the key only as a candidate — nothing in
      # Postgres stops that delete, so the page has to.
      {router, _} = DodoRouter.RoutersFixtures.router_fixture(user)
      log = DodoRouter.LogsFixtures.log_fixture(router)
      other = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Judge"})

      {:ok, _second} =
        DodoRouter.Evaluations.create_evaluation(user, log, %{
          name: "Candidate only",
          criteria: "Be useful",
          judge_model: "test-model",
          judge_provider_key_id: other.id,
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "zai_standard",
              "model" => "glm-4.6"
            }
          ]
        })

      _ = evaluation

      {:ok, live, _html} = live(conn, ~p"/providers")

      html =
        live
        |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
        |> render_click()

      # Two distinct evaluations, three roles between them — the headline
      # counts evaluations, not references.
      assert html =~ "2 evaluations"
      assert html =~ "candidate in 2"
      assert html =~ "judge of 1"
    end

    test "keeps the stored secret when the delete is refused", %{conn: conn, key: key} do
      {:ok, live, _html} = live(conn, ~p"/providers")

      live
      |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
      |> render_click()

      # the row is still there, so the secret behind it must be too — deleting
      # it first would leave a key that exists but can never authenticate
      assert DodoRouter.Providers.resolve_api_key(Repo.get(ProviderKey, key.id)) == "test-api-key"
    end
  end

  describe "key verification" do
    test "saved keys verify asynchronously and show a status badge", %{conn: conn, user: user} do
      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard"
        })

      {:ok, live, html} = live(conn, ~p"/providers")

      # unverified keys show the click-to-verify affordance
      assert html =~ "Not verified yet"

      # passive traffic marking an auth failure surfaces as invalid
      DodoRouter.Providers.apply_health(key.id, :auth_invalid, "invalid_api_key")
      {:ok, _live2, html2} = live(conn, ~p"/providers")
      assert html2 =~ "Invalid since"

      # a later success self-heals to verified
      DodoRouter.Providers.apply_health(key.id, :ok)
      {:ok, _live3, html3} = live(conn, ~p"/providers")
      assert html3 =~ "Verified"
      _ = live
    end

    test "quota exhaustion is visible inline, not only on hover", %{conn: conn, user: user} do
      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard"
        })

      DodoRouter.Providers.apply_health(key.id, :quota, "insufficient_quota")

      {:ok, live, html} = live(conn, ~p"/providers")

      # the state + age is readable without hovering — a data attribute for
      # the state, and text matching the picker's wording ("out of quota")
      assert has_element?(live, "[data-key-status='quota_exceeded']")
      assert html =~ "out of quota"
      # relative time is rendered right next to it — "just now" here since
      # the health was just applied, but the point is it's inline, not
      # buried in a title attribute only revealed on hover
      assert html =~ "out of quota · just now"
    end

    test "an unverified key shows an inline label, not just an icon", %{conn: conn, user: user} do
      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
        "provider_slug" => "zai_standard"
      })

      {:ok, live, _html} = live(conn, ~p"/providers")

      assert has_element?(live, "[data-key-status='unverified']", "unverified")
    end
  end

  describe "delete confirmation states the blast radius" do
    test "names request volume and referencing routing steps", %{conn: conn, user: user} do
      {router, _} =
        DodoRouter.RoutersFixtures.router_fixture(user, %{name: "Router A"})

      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard",
          "label" => "Prod Key"
        })

      {:ok, _step} =
        DodoRouter.Routers.create_routing_step(router, %{
          provider: "zai",
          model: "glm-4.6",
          provider_key_id: key.id
        })

      for _ <- 1..3 do
        DodoRouter.LogsFixtures.log_fixture(router, %{
          attempted_steps: [%{"provider_key_id" => key.id, "status" => "success"}]
        })
      end

      {:ok, live, _html} = live(conn, ~p"/providers")

      confirm =
        live
        |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
        |> render()

      assert confirm =~ "1 routing step"
      assert confirm =~ "Router A"
      assert confirm =~ "3 requests in the last 24h"
    end

    test "an unused key's confirmation says so — the safe-rotation signal", %{
      conn: conn,
      user: user
    } do
      key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
          "provider_slug" => "zai_standard",
          "label" => "Unused Key"
        })

      {:ok, live, _html} = live(conn, ~p"/providers")

      confirm =
        live
        |> element("button[phx-click=\"delete\"][phx-value-id=\"#{key.id}\"]")
        |> render()

      assert confirm =~ "No requests in the last 24h and no routing steps reference it"
    end
  end
end
