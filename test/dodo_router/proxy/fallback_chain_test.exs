defmodule DodoRouter.Proxy.FallbackChainTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Proxy.FallbackChain
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  defp insert_provider_key(user, provider_slug, label) do
    _key_ref = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    %ProviderKey{}
    |> ProviderKey.create_changeset(
      %{"provider_slug" => provider_slug, "label" => label},
      user.id,
      "sk•••test"
    )
    |> Repo.insert!()
  end

  defp create_step_with_key(router, user, provider, model, provider_slug, label) do
    pk = insert_provider_key(user, provider_slug, label)

    {:ok, step} =
      Routers.create_routing_step(router, %{
        "provider" => provider,
        "model" => model,
        "provider_key_id" => pk.id
      })

    Repo.preload(step, :provider_key)
  end

  describe "execute/4 with client_headers" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      step = create_step_with_key(router, user, "zai", "glm-5.1", "zai_standard", "test zai key")

      %{user: user, router: router, step: step}
    end

    test "passes client_headers list to adapter without crashing", %{
      router: router,
      step: step
    } do
      client_headers = [
        {"x-request-id", "test-123"},
        {"accept", "application/json"},
        {"authorization", "Bearer client-token"}
      ]

      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          client_headers: client_headers,
          stream: false
        )

      assert result.status == :error
      assert length(result.attempted_steps) == 1
      assert hd(result.attempted_steps).status == "error"
    end

    test "passes empty client_headers list without crashing", %{
      router: router,
      step: step
    } do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          client_headers: [],
          stream: false
        )

      assert result.status == :error
    end

    test "passes nil client_headers without crashing", %{
      router: router,
      step: step
    } do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          client_headers: nil,
          stream: false
        )

      assert result.status == :error
    end

    test "defaults client_headers to empty list when not provided", %{
      router: router,
      step: step
    } do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          stream: false
        )

      assert result.status == :error
    end
  end

  describe "execute/4 streaming with client_headers" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      step =
        create_step_with_key(router, user, "moonshot", "kimi-k2", "moonshot", "test moonshot key")

      %{user: user, router: router, step: step}
    end

    test "streaming path passes client_headers list without crashing", %{
      router: router,
      step: step
    } do
      send_chunk = fn _data -> :ok end

      client_headers = [
        {"x-session-id", "sess-abc"},
        {"authorization", "Bearer old-key"}
      ]

      result =
        FallbackChain.execute(
          %{
            "messages" => [%{"role" => "user", "content" => "hi"}],
            "model" => "test",
            "stream" => true
          },
          [step],
          router.id,
          client_headers: client_headers,
          stream: true,
          send_chunk: send_chunk
        )

      assert result.status == :error
    end

    test "streaming path handles nil client_headers without crashing", %{
      router: router,
      step: step
    } do
      send_chunk = fn _data -> :ok end

      result =
        FallbackChain.execute(
          %{
            "messages" => [%{"role" => "user", "content" => "hi"}],
            "model" => "test",
            "stream" => true
          },
          [step],
          router.id,
          client_headers: nil,
          stream: true,
          send_chunk: send_chunk
        )

      assert result.status == :error
    end
  end

  describe "execute/4 fallback behavior" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      step1 = create_step_with_key(router, user, "zai", "glm-5.1", "zai_standard", "test key 1")
      step2 = create_step_with_key(router, user, "moonshot", "kimi-k2", "moonshot", "test key 2")

      %{router: router, steps: [step1, step2]}
    end

    test "attempts all steps when providers fail", %{router: router, steps: steps} do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          steps,
          router.id,
          client_headers: [{"x-custom", "value"}],
          stream: false
        )

      assert result.status == :error
      assert length(result.attempted_steps) == 2
      assert Enum.at(result.attempted_steps, 0).provider == "zai"
      assert Enum.at(result.attempted_steps, 1).provider == "moonshot"
    end

    test "records latency for each attempt", %{router: router, steps: steps} do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          steps,
          router.id,
          stream: false
        )

      for attempt <- result.attempted_steps do
        assert is_integer(attempt.latency_ms)
        assert attempt.latency_ms >= 0
      end
    end
  end
end
