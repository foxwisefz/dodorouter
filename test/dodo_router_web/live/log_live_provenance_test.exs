defmodule DodoRouterWeb.LogLiveProvenanceTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    %{router: router}
  end

  test "assistant messages in the history are attributed to the producing log", %{
    conn: conn,
    router: router
  } do
    session_id = "sess-#{System.unique_integer([:positive])}"

    first =
      LogsFixtures.log_fixture(router, %{
        session_id: session_id,
        final_provider: "test_provider",
        final_model: "model-one",
        response_body:
          Jason.encode!(%{
            "choices" => [
              %{"message" => %{"role" => "assistant", "content" => "Paris is the capital"}}
            ]
          })
      })

    second =
      LogsFixtures.log_fixture(router, %{
        session_id: session_id,
        final_model: "model-two",
        request_body:
          Jason.encode!(%{
            "messages" => [
              %{"role" => "user", "content" => "capital of France?"},
              %{"role" => "assistant", "content" => "Paris is the capital"},
              %{"role" => "user", "content" => "and of Germany?"}
            ]
          })
      })

    {:ok, view, _html} = live(conn, ~p"/logs/#{second.id}")

    chip = ~s([title="Produced by test_provider/model-one"])
    assert has_element?(view, chip, "model-one")
    assert view |> element(chip) |> render() =~ "/logs/#{first.id}"
  end

  test "assistant history without a session gets no attribution", %{conn: conn, router: router} do
    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{
            "messages" => [
              %{"role" => "user", "content" => "q"},
              %{"role" => "assistant", "content" => "a"},
              %{"role" => "user", "content" => "q2"}
            ]
          })
      })

    {:ok, view, _html} = live(conn, ~p"/logs/#{log.id}")

    refute render(view) =~ "Produced by"
  end
end
