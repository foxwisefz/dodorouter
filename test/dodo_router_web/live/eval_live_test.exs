defmodule DodoRouterWeb.EvalLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  test "creates an evaluation from a selected log", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")
    assert has_element?(live, "#eval-form")

    live
    |> form("#candidate-picker-form", %{"picker" => %{"provider" => provider_key.id}})
    |> render_change()

    live
    |> form("#candidate-picker-form", %{
      "picker" => %{
        "provider" => provider_key.id,
        "target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    assert has_element?(live, "#selected-candidates input[value='#{provider_key.id}|test-model']") or
             has_element?(live, "#selected-candidates", "test-model")

    live
    |> form("#eval-form", %{
      "evaluation" => %{
        "name" => "Concise and correct",
        "criteria" => "Answer accurately without unnecessary detail",
        "candidate_target_values" => ["#{provider_key.id}|test-model"],
        "repetitions" => "3",
        "judge_target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    {path, _flash} = assert_redirect(live)
    assert String.starts_with?(path, "/evals/")

    assert {:ok, show_live, _html} = live(conn, URI.parse(path).path)
    assert has_element?(show_live, "#eval-summary")
  end

  test "redirects a stale evaluation URL instead of raising", %{conn: conn} do
    missing_id = Ecto.UUID.generate()

    assert {:error, {:live_redirect, %{to: "/evals"}}} = live(conn, ~p"/evals/#{missing_id}")
  end
end
