defmodule DodoRouter.Proxy.ResponseFidelityTest do
  @moduledoc """
  The response direction of the fidelity policy.

  The expensive failure this guards against: streaming responses echoed back
  the *requested* model, so a silent fallback to another provider was invisible
  from the client side — an entire agent session once ran on a different
  provider after a 429, with nothing in the response saying so. It is also a
  data-quality problem for per-agent rollups, which inherit whatever the
  response claims.
  """
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Proxy.Adapters.Anthropic
  alias DodoRouter.Proxy.FallbackChain
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures
  alias DodoRouterWeb.AnthropicFormat

  describe "the response names the model that actually answered" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      key =
        %ProviderKey{}
        |> ProviderKey.create_changeset(
          %{"provider_slug" => "test_provider", "label" => "k"},
          user.id,
          "sk-testkey"
        )
        |> Repo.insert!()

      store_key(user.id, key.key_ref, "test-api-key")

      {:ok, step} =
        Routers.create_routing_step(router, %{
          "provider" => "test_provider",
          "model" => "test-model",
          "provider_key_id" => key.id
        })

      %{router: router, step: Repo.preload(step, :provider_key), key: key}
    end

    # Production resolves provider keys through Infisical; tests seed the ETS
    # cache the resolver reads from.
    defp store_key(user_id, key_ref, api_key) do
      case :ets.whereis(:dodo_secrets_cache) do
        :undefined ->
          try do
            :ets.new(:dodo_secrets_cache, [:named_table, :public, read_concurrency: true])
          rescue
            ArgumentError -> :ok
          end

        _ ->
          :ok
      end

      :ets.insert(
        :dodo_secrets_cache,
        {"provider_key/#{user_id}/#{key_ref}", api_key,
         System.system_time(:millisecond) + 3_600_000}
      )
    end

    test "a fallback stamps the serving model, not the requested one", %{
      router: router,
      step: step
    } do
      # Step 1 fails after building its request; step 2 answers. The client
      # asked for "test-model" but "second-model" is what replied.
      steps = [
        %{step | model: "fail-model"},
        %{step | id: Ecto.UUID.generate(), position: 1, model: "second-model"}
      ]

      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test-model"},
          steps,
          router.id,
          client_headers: []
        )

      assert result.status == :fallback
      assert result.final_response["model"] == "second-model"
    end

    test "the step's model stands in when the provider reports none", %{
      router: router,
      step: step
    } do
      result =
        FallbackChain.execute(
          %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "test-model"},
          [step],
          router.id,
          client_headers: []
        )

      assert result.final_response["model"] == "test-model"
    end
  end

  describe "native Anthropic fields survive the round trip" do
    test "the resolved model is carried, not discarded" do
      ir =
        Anthropic.convert_to_openai_format(%{
          "model" => "claude-sonnet-4-5-20260514",
          "content" => [%{"type" => "text", "text" => "hi"}],
          "stop_reason" => "end_turn"
        })

      assert ir["model"] == "claude-sonnet-4-5-20260514"
      assert AnthropicFormat.from_openai_response(ir)["model"] == "claude-sonnet-4-5-20260514"
    end

    test "stop_sequence is reported instead of hardcoded nil" do
      # A client that supplies stop_sequences needs to know which one matched;
      # the egress used to answer nil unconditionally.
      ir =
        Anthropic.convert_to_openai_format(%{
          "content" => [%{"type" => "text", "text" => "hi"}],
          "stop_reason" => "stop_sequence",
          "stop_sequence" => "\n\nHuman:"
        })

      assert AnthropicFormat.from_openai_response(ir)["stop_sequence"] == "\n\nHuman:"
    end

    test "stop_sequence stays nil when no provider reported one" do
      ir = %{"choices" => [%{"message" => %{"content" => "hi"}, "finish_reason" => "stop"}]}

      assert AnthropicFormat.from_openai_response(ir)["stop_sequence"] == nil
    end
  end
end
