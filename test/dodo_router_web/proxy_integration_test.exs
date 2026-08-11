defmodule DodoRouterWeb.ProxyIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the LLM proxy API.

  These tests make actual HTTP requests through Bandit (not Plug.Test.Conn),
  ensuring streaming logic works correctly with the real HTTP server.
  This catches process-ownership bugs that are invisible to controller tests.
  """

  use DodoRouter.DataCase, async: false

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  @endpoint_url "http://localhost:4002"

  setup _tags do
    # DataCase already sets up the sandbox owner.
    # Get metadata for the current test process so the endpoint
    # can share the sandbox connection with HTTP handler processes.
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(DodoRouter.Repo, self())
    {:ok, metadata: metadata}
  end

  defp create_router_with_test_provider(_metadata) do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = RoutersFixtures.router_fixture(user)

    # Create a provider key for the test provider
    provider_key =
      %ProviderKey{}
      |> ProviderKey.create_changeset(
        %{"provider_slug" => "test_provider", "label" => "test key"},
        user.id,
        "sk-testkey"
      )
      |> Repo.insert!()

    # Store the API key in the secrets cache so FallbackChain can retrieve it.
    # In production this goes to Infisical, but in tests we bypass Infisical
    # by writing directly to the ETS cache.
    store_provider_key_in_cache(user.id, provider_key.key_ref, "test-api-key")

    # Create a routing step using the test provider
    {:ok, step} =
      Routers.create_routing_step(router, %{
        "provider" => "test_provider",
        "model" => "test-model",
        "provider_key_id" => provider_key.id
      })

    step = Repo.preload(step, :provider_key)

    %{router: router, api_key: api_key, step: step, user: user}
  end

  defp store_provider_key_in_cache(user_id, key_ref, api_key) do
    # Ensure the ETS cache table exists
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

    cache_key = "provider_key/#{user_id}/#{key_ref}"
    expires_at = System.system_time(:millisecond) + 3_600_000
    :ets.insert(:dodo_secrets_cache, {cache_key, api_key, expires_at})
  end

  defp make_request(path, body, api_key, metadata, opts \\ []) do
    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"user-agent", "test-client/1.0"}
    ]

    # Add sandbox metadata header so the endpoint process can access the DB
    encoded_metadata = Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)
    headers = [{"x-phoenix-ecto-sandbox", encoded_metadata}] ++ headers

    stream = Keyword.get(opts, :stream, false)

    if stream do
      Req.post("#{@endpoint_url}#{path}",
        headers: headers,
        json: Map.put(body, "stream", true),
        receive_timeout: 10_000
      )
    else
      Req.post("#{@endpoint_url}#{path}",
        headers: headers,
        json: body,
        receive_timeout: 10_000
      )
    end
  end

  describe "POST /r/:router_slug/v1/chat/completions (sync)" do
    test "returns successful response from provider", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata
        )

      assert response.status == 200

      assert response.body["choices"] |> hd() |> get_in(["message", "content"]) ==
               "Hello from test-model"

      assert response.headers["content-type"] == ["application/json; charset=utf-8"]
    end

    test "extracts session from default x-session-id header", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      session_id = "test-session-#{System.unique_integer([:positive])}"
      session_name = "Test Session"

      {:ok, response} =
        Req.post("#{@endpoint_url}/r/#{router.slug}/v1/chat/completions",
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"},
            {"x-phoenix-ecto-sandbox", Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)},
            {"x-session-id", session_id},
            {"x-session-name", session_name}
          ],
          json: %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          },
          receive_timeout: 10_000
        )

      assert response.status == 200

      # Verify the log was created with session info
      log = DodoRouter.Repo.get_by(DodoRouter.Logs.RequestLog, session_id: session_id)
      assert log != nil
      assert log.session_id == session_id
      assert log.session_name == session_name
    end

    test "extracts session from custom session header", %{metadata: metadata} do
      user = DodoRouter.AccountsFixtures.user_fixture()

      {router, api_key} =
        DodoRouter.RoutersFixtures.router_fixture(user, %{session_header: "x-session-affinity"})

      # Create provider and routing step
      provider_key =
        %DodoRouter.Providers.ProviderKey{}
        |> DodoRouter.Providers.ProviderKey.create_changeset(
          %{"provider_slug" => "test_provider", "label" => "test key"},
          user.id,
          "sk-testkey"
        )
        |> DodoRouter.Repo.insert!()

      # Ensure the ETS cache table exists
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

      cache_key = "provider_key/#{user.id}/#{provider_key.key_ref}"
      expires_at = System.system_time(:millisecond) + 3_600_000
      :ets.insert(:dodo_secrets_cache, {cache_key, "test-api-key", expires_at})

      {:ok, _step} =
        DodoRouter.Routers.create_routing_step(router, %{
          "provider" => "test_provider",
          "model" => "test-model",
          "provider_key_id" => provider_key.id
        })

      session_id = "ses_#{System.unique_integer([:positive])}"
      session_name = "RTK Session"

      {:ok, response} =
        Req.post("#{@endpoint_url}/r/#{router.slug}/v1/chat/completions",
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"},
            {"x-phoenix-ecto-sandbox", Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)},
            {"x-session-affinity", session_id},
            {"x-session-affinity-name", session_name}
          ],
          json: %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          },
          receive_timeout: 10_000
        )

      assert response.status == 200

      # Verify the log was created with custom session header info
      log = DodoRouter.Repo.get_by(DodoRouter.Logs.RequestLog, session_id: session_id)
      assert log != nil
      assert log.session_id == session_id
      assert log.session_name == session_name
    end

    test "returns 400 when no routing configured", %{metadata: metadata} do
      {router, api_key} = RoutersFixtures.router_fixture()

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata
        )

      assert response.status == 400
      assert response.body["error"]["type"] == "invalid_request_error"
    end
  end

  describe "POST /r/:router_slug/v1/chat/completions (streaming)" do
    test "returns successful SSE stream from provider", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata,
          stream: true
        )

      assert response.status == 200
      assert response.headers["content-type"] == ["text/event-stream; charset=utf-8"]

      # Parse SSE events from the response body
      body = response.body
      events = parse_sse_events(body)

      # Should have content chunks + [DONE]
      content_events = Enum.reject(events, &(&1 == :done))
      assert length(content_events) > 0

      # Verify content was streamed
      full_content =
        content_events
        |> Enum.map(fn event ->
          get_in(event, ["choices", Access.at(0), "delta", "content"]) || ""
        end)
        |> Enum.join()

      assert String.contains?(full_content, "Hello")

      # Verify [DONE] event is present
      assert :done in events
    end

    test "returns HTTP 400 JSON error when no routing configured (not SSE)", %{metadata: metadata} do
      {router, api_key} = RoutersFixtures.router_fixture()

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata,
          stream: true
        )

      # When no providers are configured and no chunks were sent,
      # we should get HTTP 400 with JSON error — not HTTP 200 with SSE events.
      # This ensures client SDKs (e.g. AI SDK) detect the error as APICallError.
      assert response.status == 400
      assert response.headers["content-type"] == ["application/json; charset=utf-8"]
      assert response.body["error"]["message"] == "No routing configured"
    end

    test "falls back to next provider when first fails mid-stream", %{metadata: metadata} do
      user = AccountsFixtures.user_fixture()
      {router, api_key} = RoutersFixtures.router_fixture(user)

      # Create a provider key for a provider that doesn't exist in adapters
      # This will cause an auth error (no adapter found, or missing key)
      # Actually, let's create two steps: first one with a provider that will fail,
      # second one with test_provider that succeeds.

      # Create a fake provider key that will cause auth_error
      fake_key =
        %ProviderKey{}
        |> ProviderKey.create_changeset(
          %{"provider_slug" => "openai", "label" => "fake key"},
          user.id,
          "sk-fake"
        )
        |> Repo.insert!()

      {:ok, failing_step} =
        Routers.create_routing_step(router, %{
          "provider" => "openai",
          "model" => "gpt-4o",
          "provider_key_id" => fake_key.id
        })

      # Create a test provider key that will succeed
      test_key =
        %ProviderKey{}
        |> ProviderKey.create_changeset(
          %{"provider_slug" => "test_provider", "label" => "test key"},
          user.id,
          "sk-testkey"
        )
        |> Repo.insert!()

      store_provider_key_in_cache(user.id, test_key.key_ref, "test-api-key")

      {:ok, success_step} =
        Routers.create_routing_step(router, %{
          "provider" => "test_provider",
          "model" => "test-model",
          "provider_key_id" => test_key.id
        })

      # Preload steps
      _failing_step = Repo.preload(failing_step, :provider_key)
      _success_step = Repo.preload(success_step, :provider_key)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata,
          stream: true
        )

      # The first provider fails, fallback to test_provider succeeds
      assert response.status == 200
      assert response.headers["content-type"] == ["text/event-stream; charset=utf-8"]

      body = response.body
      events = parse_sse_events(body)
      content_events = Enum.reject(events, &(&1 == :done))
      assert length(content_events) > 0
      assert :done in events
    end
  end

  describe "POST /r/:router_slug/v1/messages (Anthropic sync)" do
    test "returns successful Anthropic-format response", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/messages",
          %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "max_tokens" => 1024
          },
          api_key,
          metadata
        )

      assert response.status == 200
      assert response.headers["content-type"] == ["application/json; charset=utf-8"]

      body = response.body
      assert body["type"] == "message"
      assert body["role"] == "assistant"
      assert get_in(body, ["content", Access.at(0), "text"]) == "Hello from test-model"
    end

    test "returns 400 when no routing configured", %{metadata: metadata} do
      {router, api_key} = RoutersFixtures.router_fixture()

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/messages",
          %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "max_tokens" => 1024
          },
          api_key,
          metadata
        )

      assert response.status == 400
      assert get_in(response.body, ["error", "type"]) == "invalid_request_error"
    end
  end

  describe "POST /r/:router_slug/v1/messages (Anthropic streaming)" do
    test "returns successful Anthropic-format SSE stream", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/messages",
          %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "max_tokens" => 1024
          },
          api_key,
          metadata,
          stream: true
        )

      assert response.status == 200
      assert response.headers["content-type"] == ["text/event-stream; charset=utf-8"]

      events = parse_anthropic_sse_events(response.body)

      # Should have content_delta events
      content_deltas =
        Enum.filter(events, fn e ->
          is_map(e) && e["type"] == "content_block_delta"
        end)

      assert length(content_deltas) > 0

      full_content =
        content_deltas
        |> Enum.map(&(get_in(&1, ["delta", "text"]) || ""))
        |> Enum.join()

      assert String.contains?(full_content, "Hello")
    end

    test "emits correct Anthropic SSE lifecycle event order", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/messages",
          %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "max_tokens" => 1024
          },
          api_key,
          metadata,
          stream: true
        )

      assert response.status == 200
      assert response.headers["content-type"] == ["text/event-stream; charset=utf-8"]

      events = parse_anthropic_sse_events(response.body)
      event_types = Enum.map(events, & &1["type"])

      assert hd(event_types) == "message_start"
      assert List.last(event_types) == "message_stop"

      content_delta_index =
        Enum.find_index(event_types, &(&1 == "content_block_delta"))

      content_block_start_index =
        Enum.find_index(event_types, &(&1 == "content_block_start"))

      content_block_stop_index =
        Enum.find_index(event_types, &(&1 == "content_block_stop"))

      message_delta_index =
        Enum.find_index(event_types, &(&1 == "message_delta"))

      message_stop_index =
        Enum.find_index(event_types, &(&1 == "message_stop"))

      assert content_block_start_index < content_delta_index
      assert content_block_stop_index > content_delta_index
      assert message_delta_index < message_stop_index
      assert message_stop_index == length(event_types) - 1

      message_delta = Enum.at(events, message_delta_index)
      assert message_delta["delta"]["stop_reason"] == "end_turn"
      assert get_in(message_delta, ["usage", "output_tokens"]) == 5

      message_start = Enum.at(events, 0)
      assert get_in(message_start, ["message", "role"]) == "assistant"
      assert get_in(message_start, ["message", "content"]) == []
    end

    test "message_start names the model that actually answered", %{metadata: metadata} do
      # A silent fallback used to be invisible: message_start echoed the model
      # the client asked for, so an agent session could run entirely on another
      # provider with nothing in the stream to say so.
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/messages",
          %{
            "model" => "a-model-the-router-does-not-use",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "max_tokens" => 1024
          },
          api_key,
          metadata,
          stream: true
        )

      assert response.status == 200

      message_start =
        response.body
        |> parse_anthropic_sse_events()
        |> Enum.find(&(is_map(&1) and &1["type"] == "message_start"))

      assert get_in(message_start, ["message", "model"]) == "test-model"
    end

    test "returns a real HTTP error when the request fails before any content",
         %{metadata: metadata} do
      # The 200 is deferred until the first chunk. A request that never
      # produces one still has a revisable status, so the client's SDK sees an
      # error instead of an empty successful stream — the OpenAI-shaped
      # endpoint has always behaved this way.
      {router, api_key} = RoutersFixtures.router_fixture()

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/messages",
          %{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "max_tokens" => 1024
          },
          api_key,
          metadata,
          stream: true
        )

      assert response.status == 400

      assert response.body["type"] == "error"
      assert response.body["error"]["message"] == "No routing configured"
    end
  end

  describe "POST /v1/chat/completions (legacy)" do
    test "returns successful sync response", %{metadata: metadata} do
      %{api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata
        )

      assert response.status == 200

      assert response.body["choices"] |> hd() |> get_in(["message", "content"]) ==
               "Hello from test-model"
    end
  end

  describe "x-request-id" do
    # The header is the only handle a user has on a request. If it does not
    # name the row we logged, an operator handed one cannot find the request —
    # and streaming is most agent traffic.
    for {label, path, body} <- [
          {"OpenAI streaming", "/v1/chat/completions",
           %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]}},
          {"Anthropic streaming", "/v1/messages",
           %{
             "model" => "test-model",
             "messages" => [%{"role" => "user", "content" => "Hello"}],
             "max_tokens" => 1024
           }},
          {"Responses streaming", "/v1/responses", %{"model" => "test-model", "input" => "Hello"}}
        ] do
      test "#{label} logs the request id it handed the client", %{metadata: metadata} do
        %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

        {:ok, response} =
          make_request(
            "/r/#{router.slug}#{unquote(path)}",
            unquote(Macro.escape(body)),
            api_key,
            metadata,
            stream: true
          )

        assert response.status == 200
        [request_id] = response.headers["x-request-id"]

        assert DodoRouter.Repo.get_by(DodoRouter.Logs.RequestLog, request_id: request_id),
               "no log row carries the request id the client was handed"
      end
    end

    test "sync keeps matching too", %{metadata: metadata} do
      %{router: router, api_key: api_key} = create_router_with_test_provider(metadata)

      {:ok, response} =
        make_request(
          "/r/#{router.slug}/v1/chat/completions",
          %{"model" => "test-model", "messages" => [%{"role" => "user", "content" => "Hello"}]},
          api_key,
          metadata
        )

      [request_id] = response.headers["x-request-id"]
      assert DodoRouter.Repo.get_by(DodoRouter.Logs.RequestLog, request_id: request_id)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp parse_sse_events(body) when is_binary(body) do
    body
    |> String.split("\n\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case line do
        "data: [DONE]" ->
          :done

        "data: " <> json ->
          case Jason.decode(json) do
            {:ok, parsed} -> parsed
            {:error, _} -> {:raw, json}
          end

        _ ->
          {:raw, line}
      end
    end)
  end

  defp parse_anthropic_sse_events(body) when is_binary(body) do
    body
    |> String.split("\n\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn block ->
      lines = String.split(block, "\n")

      event_type =
        Enum.find_value(lines, fn line ->
          case line do
            "event: " <> name -> name
            _ -> nil
          end
        end)

      data_line =
        Enum.find(lines, fn line -> String.starts_with?(line, "data: ") end)

      case data_line do
        "data: " <> json ->
          case Jason.decode(json) do
            {:ok, parsed} -> Map.put(parsed, "type", event_type || parsed["type"])
            {:error, _} -> %{"type" => event_type, "raw" => json}
          end

        nil ->
          %{"type" => event_type}
      end
    end)
  end
end
