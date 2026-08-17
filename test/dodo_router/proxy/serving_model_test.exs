defmodule DodoRouter.Proxy.ServingModelTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  # A provider that reports "" as its model — the class of answer that made
  # clients fall back to the requested model and persist wrong provenance
  # (dodo_router-bnn). The proxy must overwrite a blank claim with the step's
  # model, while a provider naming its own resolved snapshot still wins.
  defp router_with(user, model) do
    {router, api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "key for #{model}"})

    {:ok, _step} =
      Routers.create_routing_step(router, %{
        position: 0,
        provider: "test_provider",
        model: model,
        provider_key_id: key.id
      })

    {router, api_key}
  end

  defp chat(router, api_key, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> put_req_header("content-type", "application/json")
    |> post("/r/#{router.slug}/v1/chat/completions", body)
  end

  test "a blank provider model claim is overwritten with the serving step's model" do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = router_with(user, "empty-model-model")

    response =
      chat(router, api_key, %{
        "model" => "whatever-the-client-asked-for",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })
      |> json_response(200)

    assert response["model"] == "empty-model-model"
  end

  test "a provider naming its own resolved snapshot still wins" do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = router_with(user, "alias-model")

    response =
      chat(router, api_key, %{
        "model" => "whatever",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })
      |> json_response(200)

    assert response["model"] == "alias-model-v2"
  end

  test "the Anthropic egress serves the step model, never an empty string" do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = router_with(user, "empty-model-model")

    response =
      build_conn()
      |> put_req_header("x-api-key", api_key)
      |> put_req_header("content-type", "application/json")
      |> post("/r/#{router.slug}/v1/messages", %{
        "model" => "whatever",
        "max_tokens" => 64,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })
      |> json_response(200)

    assert response["model"] == "empty-model-model"
  end
end
