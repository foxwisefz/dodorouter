defmodule DodoRouter.Proxy.FidelityTest do
  @moduledoc """
  The load-bearing half of the request-fidelity policy: whatever the proxy
  removes or rewrites has to end up on the request log. "The provider will
  break" is not knowable in advance for every provider × header pair, so the
  strip list grows by accretion after outages — and without a record, each
  entry becomes folklore nobody can trace back to a reason.

  These tests drive `Proxy.dispatch/3` end to end and read the persisted row,
  rather than asserting on the recorder in isolation: the plumbing between the
  policy functions and the log is exactly the part that was missing.
  """
  use DodoRouter.DataCase, async: false

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Proxy
  alias DodoRouter.Proxy.Fidelity
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {router, _api_key} = RoutersFixtures.router_fixture(user)

    provider_key =
      %ProviderKey{}
      |> ProviderKey.create_changeset(
        %{"provider_slug" => "test_provider", "label" => "test key"},
        user.id,
        "sk-testkey"
      )
      |> Repo.insert!()

    store_key(user.id, provider_key.key_ref, "test-api-key")

    {:ok, step} =
      Routers.create_routing_step(router, %{
        "provider" => "test_provider",
        "model" => "test-model",
        "provider_key_id" => provider_key.id
      })

    %{router: router, step: Repo.preload(step, :provider_key)}
  end

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

  defp dispatch(router, request, opts) do
    {:ok, _response, %{log: log}} =
      Proxy.dispatch(router, request, Keyword.merge([log_mode: :sync], opts))

    log
  end

  defp request, do: %{"messages" => [%{"role" => "user", "content" => "hi"}], "model" => "x"}

  defp find(log, channel, name) do
    Enum.find(log.fidelity_changes, &(&1["channel"] == channel and &1["name"] == name))
  end

  describe "channel 1: request headers" do
    test "a stripped header is recorded with the policy reason that stripped it", %{
      router: router
    } do
      log =
        dispatch(router, request(),
          client_headers: [
            {"cookie", "_dodo_router_key=secret"},
            {"accept-encoding", "gzip"},
            {"openai-organization", "org-client"},
            {"authorization", "Bearer client-token"},
            {"x-client-trace", "keep-me"}
          ]
        )

      assert find(log, "request_header", "cookie")["reason"] == "not_client_sent"
      assert find(log, "request_header", "accept-encoding")["reason"] == "transport"
      assert find(log, "request_header", "openai-organization")["reason"] == "account_scoped"
      assert find(log, "request_header", "authorization")["reason"] == "replaced_by_proxy"

      # Forwarded headers are not changes — recording them would bury the
      # handful of drops under everything a coding agent sends.
      refute find(log, "request_header", "x-client-trace")
    end

    test "every recorded reason can be explained to an operator", %{router: router} do
      log = dispatch(router, request(), client_headers: [{"cookie", "x"}, {"host", "y"}])

      for change <- log.fidelity_changes do
        explanation = Fidelity.explain(change["reason"])
        assert is_binary(explanation) and explanation != change["reason"]
      end
    end

    test "each change names the provider and step that produced it", %{router: router} do
      log = dispatch(router, request(), client_headers: [{"cookie", "x"}])

      change = find(log, "request_header", "cookie")
      assert change["provider"] == "test_provider"
      assert change["step"] == 0
    end

    test "outbound_headers is populated from the policy point, not per adapter", %{
      router: router
    } do
      log = dispatch(router, request(), client_headers: [{"x-client-trace", "abc"}])

      [attempt] = log.attempted_steps
      assert ["x-client-trace", "abc"] in attempt["outbound_headers"]
    end
  end

  describe "channel 2: request body" do
    test "a field the egress allowlist does not carry is recorded", %{router: router} do
      log =
        dispatch(router, Map.put(request(), "logit_bias", %{"1" => 1}), client_headers: [])

      change = find(log, "request_body", "logit_bias")
      assert change["action"] == "dropped"
      assert change["reason"] == "not_in_provider_allowlist"
    end

    test "router_slug is not reported — the client never sent it", %{router: router} do
      # It comes from the URL path via Phoenix. Reporting it would put a
      # spurious "the proxy dropped a field" line on every single request.
      log = dispatch(router, Map.put(request(), "router_slug", router.slug), client_headers: [])

      refute find(log, "request_body", "router_slug")
    end

    test "fields lost by an ingress format conversion are recorded too", %{router: router} do
      log =
        dispatch(router, request(),
          client_headers: [],
          dropped_request_fields: ["context_management"],
          dropped_request_fields_detail: "anthropic -> openai request conversion"
        )

      change = find(log, "request_body", "context_management")
      assert change["reason"] == "unsupported_by_format_conversion"
      assert change["detail"] == "anthropic -> openai request conversion"
    end
  end

  describe "a clean request records nothing" do
    test "no changes means an empty list, not a row full of noise", %{router: router} do
      log = dispatch(router, request(), client_headers: [{"x-client-trace", "abc"}])

      assert log.fidelity_changes == []
    end
  end

  describe "per-step isolation" do
    test "a step's record does not carry the previous step's drops", %{
      router: router,
      step: step
    } do
      # Two identical steps; the first fails and falls back to the second.
      # Both run the same policy, so both must report the same drop once —
      # never the first step's drop attributed twice to the second.
      {:ok, second} =
        Routers.create_routing_step(router, %{
          "provider" => "test_provider",
          "model" => "test-model",
          "provider_key_id" => step.provider_key_id
        })

      steps = [%{step | model: "fail-model"}, Repo.preload(second, :provider_key)]

      log =
        dispatch(router, request(),
          steps: steps,
          client_headers: [{"cookie", "x"}]
        )

      cookie_changes =
        Enum.filter(log.fidelity_changes, &(&1["name"] == "cookie"))

      assert length(cookie_changes) == length(log.attempted_steps)
      assert Enum.map(cookie_changes, & &1["step"]) == Enum.map(steps, & &1.position)
    end
  end
end
