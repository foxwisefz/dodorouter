defmodule DodoRouterWeb.IdempotencyTest do
  use DodoRouterWeb.ConnCase, async: true

  import Ecto.Query

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Proxy.IdempotencyKey
  alias DodoRouter.Repo
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)

    {:ok, _step} =
      Routers.create_routing_step(router, %{
        position: 0,
        provider: "test_provider",
        model: "test-model",
        provider_key_id: key.id
      })

    %{user: user, router: router, api_key: api_key, provider_key: key}
  end

  defp chat(router, api_key, body, headers) do
    Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> put_req_header("content-type", "application/json")
    |> post("/r/#{router.slug}/v1/chat/completions", body)
  end

  defp body(text) do
    %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => text}]
    }
  end

  defp logs(router) do
    from(l in RequestLog, where: l.router_id == ^router.id, order_by: [asc: l.inserted_at])
    |> Repo.all()
  end

  test "a repeated key re-serves the stored answer at zero cost", %{
    router: router,
    api_key: api_key
  } do
    first = chat(router, api_key, body("hello"), [{"idempotency-key", "meeting-3821-q7"}])
    assert %{"choices" => [%{"message" => %{"content" => content}}]} = json_response(first, 200)
    assert get_resp_header(first, "idempotent-replayed") == []

    second = chat(router, api_key, body("hello"), [{"idempotency-key", "meeting-3821-q7"}])
    assert %{"choices" => [%{"message" => %{"content" => ^content}}]} = json_response(second, 200)
    assert get_resp_header(second, "idempotent-replayed") == ["true"]

    # Two rows — the audit sees every served request — but the answer and
    # its cost exist exactly once.
    assert [original, replay] = logs(router)
    assert original.idempotency_key == "meeting-3821-q7"
    assert original.idempotent_replay_of_id == nil

    assert replay.idempotency_key == "meeting-3821-q7"
    assert replay.idempotent_replay_of_id == original.id
    assert replay.total_tokens == 0
    assert Decimal.equal?(replay.estimated_cost_usd, 0)
    assert Decimal.equal?(replay.list_cost_usd, 0)
    assert replay.response_body == "null"
    assert replay.final_model == original.final_model

    # The header was consumed here, not forwarded — and the record says so.
    changes = original.fidelity_changes || []

    assert Enum.any?(
             changes,
             &(&1["name"] == "idempotency-key" and &1["reason"] == "fulfilled_by_proxy")
           )

    assert %{status: "completed"} =
             Repo.get_by(IdempotencyKey, router_id: router.id, key: "meeting-3821-q7")
  end

  test "a reused key with a different body is rejected, never served-anyway", %{
    router: router,
    api_key: api_key
  } do
    assert chat(router, api_key, body("hello"), [{"idempotency-key", "k1"}])
           |> json_response(200)

    conflict = chat(router, api_key, body("goodbye"), [{"idempotency-key", "k1"}])
    assert %{"error" => error} = json_response(conflict, 409)
    assert error["code"] == "idempotency_key_reused"

    # Only the original ever reached upstream.
    assert [_original] = logs(router)
  end

  test "a retry racing the original gets a retry-later, not a second execution", %{
    router: router,
    api_key: api_key
  } do
    # A real first request writes the reservation with the true hash; winding
    # its status back is the state a still-executing original holds.
    assert chat(router, api_key, body("hello"), [{"idempotency-key", "k-inflight"}])
           |> json_response(200)

    Repo.get_by(IdempotencyKey, router_id: router.id, key: "k-inflight")
    |> Ecto.Changeset.change(status: "in_progress", updated_at: DateTime.utc_now())
    |> Repo.update!()

    conflict = chat(router, api_key, body("hello"), [{"idempotency-key", "k-inflight"}])
    assert %{"error" => error} = json_response(conflict, 409)
    assert error["code"] == "idempotency_in_progress"

    # Only the original ever reached upstream.
    assert [_original] = logs(router)
  end

  test "errors are not stored — a retry executes fresh", %{user: user} do
    # The routing step decides what serves the request; a fail-model step
    # makes every upstream call fail.
    {failing_router, failing_api_key} = RoutersFixtures.router_fixture(user)
    failing_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "failing key"})

    {:ok, _step} =
      Routers.create_routing_step(failing_router, %{
        position: 0,
        provider: "test_provider",
        model: "fail-model",
        provider_key_id: failing_key.id
      })

    refute chat(failing_router, failing_api_key, body("hello"), [{"idempotency-key", "k-err"}]).status ==
             200

    # The failed dispatch released its reservation...
    assert Repo.get_by(IdempotencyKey, router_id: failing_router.id, key: "k-err") == nil

    # ...so the retry pays upstream again instead of replaying a stored 502.
    refute chat(failing_router, failing_api_key, body("hello"), [{"idempotency-key", "k-err"}]).status ==
             200

    assert [first, second] = logs(failing_router)
    assert first.idempotent_replay_of_id == nil
    assert second.idempotent_replay_of_id == nil
  end

  test "a streaming request with a key is refused, not silently un-guaranteed", %{
    router: router,
    api_key: api_key
  } do
    conn =
      chat(router, api_key, Map.put(body("hello"), "stream", true), [
        {"idempotency-key", "k-stream"}
      ])

    assert %{"error" => %{"type" => "invalid_request_error", "message" => message}} =
             json_response(conn, 400)

    assert message =~ "streaming"
    assert logs(router) == []
  end

  test "keys are scoped per router", %{user: user, router: router, api_key: api_key} do
    {other_router, other_api_key} = RoutersFixtures.router_fixture(user)
    other_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "second key"})

    {:ok, _step} =
      Routers.create_routing_step(other_router, %{
        position: 0,
        provider: "test_provider",
        model: "test-model",
        provider_key_id: other_key.id
      })

    assert chat(router, api_key, body("hello"), [{"idempotency-key", "shared"}])
           |> json_response(200)

    other = chat(other_router, other_api_key, body("hello"), [{"idempotency-key", "shared"}])
    assert json_response(other, 200)
    # Fresh execution, not a replay of the first router's answer.
    assert get_resp_header(other, "idempotent-replayed") == []
  end

  test "an expired key executes fresh", %{router: router, api_key: api_key} do
    request = body("hello")

    %IdempotencyKey{
      router_id: router.id,
      key: "k-old",
      request_hash: DodoRouter.Proxy.Idempotency.request_hash(request),
      request_id: Ecto.UUID.generate(),
      status: "completed"
    }
    |> Repo.insert!()
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour))
    |> Repo.update!()

    conn = chat(router, api_key, request, [{"idempotency-key", "k-old"}])
    assert json_response(conn, 200)
    assert get_resp_header(conn, "idempotent-replayed") == []

    # The fresh execution took the key over.
    assert %{status: "completed"} =
             row = Repo.get_by(IdempotencyKey, router_id: router.id, key: "k-old")

    assert DateTime.diff(DateTime.utc_now(), row.inserted_at, :second) < 60
  end

  test "a truncated stored response executes fresh rather than replaying corruption", %{
    router: router,
    api_key: api_key
  } do
    assert chat(router, api_key, body("hello"), [{"idempotency-key", "k-trunc"}])
           |> json_response(200)

    [original] = logs(router)

    # Simulate what the log writer does to an oversized response.
    doctored =
      original.response_body
      |> Jason.decode!()
      |> Map.put("_truncation_flags", ["response_text_truncated"])
      |> Jason.encode!()

    original |> Ecto.Changeset.change(response_body: doctored) |> Repo.update!()

    retry = chat(router, api_key, body("hello"), [{"idempotency-key", "k-trunc"}])
    assert json_response(retry, 200)
    assert get_resp_header(retry, "idempotent-replayed") == []

    # Two real upstream calls, no replay row.
    assert [_first, second] = logs(router)
    assert second.idempotent_replay_of_id == nil
  end

  test "a stored body from before model-stamping replays with the log's final_model", %{
    router: router,
    api_key: api_key
  } do
    assert chat(router, api_key, body("hello"), [{"idempotency-key", "k-nomodel"}])
           |> json_response(200)

    [original] = logs(router)

    # Rows logged before stamp_serving_model existed carry no model at all.
    doctored = original.response_body |> Jason.decode!() |> Map.delete("model") |> Jason.encode!()
    original |> Ecto.Changeset.change(response_body: doctored) |> Repo.update!()

    replayed = chat(router, api_key, body("hello"), [{"idempotency-key", "k-nomodel"}])
    assert get_resp_header(replayed, "idempotent-replayed") == ["true"]
    assert json_response(replayed, 200)["model"] == original.final_model
  end

  describe "Anthropic endpoint" do
    defp messages(router, api_key, payload, headers) do
      Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> put_req_header("x-api-key", api_key)
      |> put_req_header("content-type", "application/json")
      |> post("/r/#{router.slug}/v1/messages", payload)
    end

    test "replays come back in the client's own format", %{router: router, api_key: api_key} do
      payload = %{
        "model" => "test-model",
        "max_tokens" => 64,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      first = messages(router, api_key, payload, [{"idempotency-key", "row-42"}])

      assert %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]} =
               json_response(first, 200)

      second = messages(router, api_key, payload, [{"idempotency-key", "row-42"}])

      # The stored IR is re-rendered by this endpoint's own egress: an
      # Anthropic-shaped body, not the OpenAI shape the log stores.
      assert %{"role" => "assistant", "content" => [%{"type" => "text", "text" => ^text}]} =
               json_response(second, 200)

      assert get_resp_header(second, "idempotent-replayed") == ["true"]

      conflict =
        messages(
          router,
          api_key,
          put_in(payload["messages"], [%{"role" => "user", "content" => "bye"}]),
          [{"idempotency-key", "row-42"}]
        )

      assert %{"type" => "error", "error" => %{"type" => "idempotency_error"}} =
               json_response(conflict, 409)
    end
  end
end
