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

  describe "execute/4 error details" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      %{user: user, router: router}
    end

    test "populates error_body when API key is missing", %{user: _user, router: router} do
      {:ok, step} =
        Routers.create_routing_step(router, %{
          "provider" => "openai",
          "model" => "gpt-4o"
        })

      step = Repo.preload(step, :provider_key)

      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          stream: false
        )

      attempt = hd(result.attempted_steps)
      assert attempt.error == "auth_error"
      assert attempt.error_body != nil
      assert String.contains?(attempt.error_body, "Missing API key")
    end

    test "records error and error_body for failed attempts", %{user: user, router: router} do
      step = create_step_with_key(router, user, "zai", "glm-5.1", "zai_standard", "test key")

      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          stream: false
        )

      attempt = hd(result.attempted_steps)
      assert attempt.status == "error"
      assert attempt.error != nil
      assert attempt.error_body != nil
      assert is_integer(attempt.latency_ms)
    end
  end

  describe "error_body_fallback" do
    test "returns timeout message for :timeout" do
      chain_module = DodoRouter.Proxy.FallbackChain
      result = chain_module.error_body_fallback(:timeout, %{})
      assert result == "Request timed out"
    end

    test "returns reason string for auth_error" do
      result =
        DodoRouter.Proxy.FallbackChain.error_body_fallback(:auth_error, %{reason: "bad key"})

      assert result == "bad key"
    end

    test "returns stringified reason as fallback" do
      result = DodoRouter.Proxy.FallbackChain.error_body_fallback(:server_error, %{})
      assert result == "server_error"
    end

    test "includes HTTP status in fallback" do
      result = DodoRouter.Proxy.FallbackChain.error_body_fallback(:auth_error, %{status: 403})
      assert result == "HTTP 403: auth_error"
    end
  end

  describe "should_fallback?/3" do
    test "returns true for context_overflow when fail_on_context_overflow is false" do
      assert FallbackChain.should_fallback?(:context_overflow, 2, false) == true
    end

    test "returns false for context_overflow when fail_on_context_overflow is true" do
      assert FallbackChain.should_fallback?(:context_overflow, 2, true) == false
    end

    test "returns false for context_overflow when no remaining steps" do
      assert FallbackChain.should_fallback?(:context_overflow, 0, false) == false
      assert FallbackChain.should_fallback?(:context_overflow, 0, true) == false
    end

    test "still allows fallback for other errors when fail_on_context_overflow is true" do
      assert FallbackChain.should_fallback?(:rate_limited, 2, true) == true
      assert FallbackChain.should_fallback?(:server_error, 2, true) == true
      assert FallbackChain.should_fallback?(:timeout, 2, true) == true
    end

    test "returns false for non-fallback errors regardless of setting" do
      assert FallbackChain.should_fallback?(:success, 2, false) == false
      assert FallbackChain.should_fallback?(:success, 2, true) == false
    end
  end

  describe "attempt metadata tracking" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      step_with_key =
        create_step_with_key(router, user, "zai", "glm-5.1", "zai_standard", "production key")

      {:ok, step_without_key} =
        Routers.create_routing_step(router, %{
          "provider" => "openai",
          "model" => "gpt-4o"
        })

      step_without_key = Repo.preload(step_without_key, :provider_key)

      %{router: router, step_with_key: step_with_key, step_without_key: step_without_key}
    end

    test "records endpoint in attempt", %{router: router, step_with_key: step} do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          stream: false
        )

      attempt = hd(result.attempted_steps)
      assert String.contains?(attempt.endpoint, "api.z.ai")
      assert String.ends_with?(attempt.endpoint, "/chat/completions")
    end

    test "records provider_key_id and label when key is assigned", %{
      router: router,
      step_with_key: step
    } do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          stream: false
        )

      attempt = hd(result.attempted_steps)
      assert attempt.provider_key_id == step.provider_key.id
      assert attempt.provider_key_label == "production key"
    end

    test "records nil provider_key_id and label when no key is assigned", %{
      router: router,
      step_without_key: step
    } do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test"},
          [step],
          router.id,
          stream: false
        )

      attempt = hd(result.attempted_steps)
      assert attempt.provider_key_id == nil
      assert attempt.provider_key_label == nil
    end
  end

  describe "truncate_error" do
    test "returns nil for nil" do
      assert DodoRouter.Proxy.FallbackChain.truncate_error(nil) == nil
    end

    test "returns nil for empty string" do
      assert DodoRouter.Proxy.FallbackChain.truncate_error("") == nil
    end

    test "truncates large map bodies" do
      body = %{"error" => %{"message" => String.duplicate("x", 600)}}
      result = DodoRouter.Proxy.FallbackChain.truncate_error(body)
      assert String.ends_with?(result, "...")
      assert byte_size(result) <= 503
    end

    test "preserves small map bodies as JSON" do
      body = %{"error" => %{"message" => "rate limited"}}
      result = DodoRouter.Proxy.FallbackChain.truncate_error(body)
      assert result =~ "rate limited"
      assert String.starts_with?(result, "{")
    end
  end
end
