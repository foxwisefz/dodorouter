defmodule DodoRouterWeb.MCPControllerTest do
  @moduledoc """
  The 2026-07-28 transport rules. These are the parts a hand-rolled protocol
  gets wrong quietly — a header the server forgot to compare against the body
  is invisible until an intermediary routes on one and the server acts on the
  other.
  """

  use DodoRouterWeb.ConnCase, async: true

  import Ecto.Query

  alias DodoRouter.Agents
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.AuthZFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  @version "2026-07-28"

  setup do
    user = AccountsFixtures.user_fixture()
    {router, proxy_key} = RoutersFixtures.router_fixture(user)

    %{
      user: user,
      router: router,
      proxy_key: proxy_key,
      token: AuthZFixtures.access_token(user)
    }
  end

  # Builds a spec-shaped request: the mirrored headers are derived from the
  # body, exactly as a conforming client must derive them.
  defp rpc(conn, token, method, params \\ nil, opts \\ []) do
    id = Keyword.get(opts, :id, 1)
    version = Keyword.get(opts, :version, @version)

    body =
      %{"jsonrpc" => "2.0", "method" => method}
      |> then(&if id, do: Map.put(&1, "id", id), else: &1)
      |> then(&if params, do: Map.put(&1, "params", params), else: &1)

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("mcp-protocol-version", Keyword.get(opts, :protocol_header, version))
    |> put_req_header("mcp-method", Keyword.get(opts, :method_header, method))
    |> then(fn c ->
      case Keyword.get(opts, :name_header, params && params["name"]) do
        nil -> c
        name -> put_req_header(c, "mcp-name", name)
      end
    end)
    |> then(fn c ->
      case opts[:origin] do
        nil -> c
        origin -> put_req_header(c, "origin", origin)
      end
    end)
    |> post("/mcp", body)
  end

  defp tool_json(response) do
    response["result"]["structuredContent"]
  end

  describe "transport rules" do
    test "requires a credential", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "tools/list")
        |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert json_response(conn, 401)["error"] == "invalid_token"
    end

    test "GET and DELETE are 405 — those were the removed session verbs", %{
      conn: conn,
      token: token
    } do
      authed = put_req_header(conn, "authorization", "Bearer #{token}")

      for c <- [get(authed, "/mcp"), delete(authed, "/mcp")] do
        assert json_response(c, 405)["error"]["message"] =~ "POST only"
        assert get_resp_header(c, "allow") == ["POST"]
      end
    end

    test "a missing protocol version header means a legacy client, not an error", %{
      conn: conn,
      token: token
    } do
      # Claude Code opens with exactly this: `initialize`, no MCP-Protocol-Version
      # header, no mirrored headers. Refusing it is a 400 the client cannot act
      # on, and a modern-only endpoint it cannot connect to is not an interface.
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
        })

      result = json_response(conn, 200)["result"]
      # Its own version echoed back: the tool surface is identical across these
      # revisions, so there is nothing to downgrade.
      assert result["protocolVersion"] == "2025-06-18"
      assert result["capabilities"]["tools"]
      assert result["serverInfo"]["name"] == "dodo-router"
    end

    test "a legacy client can call tools without the mirrored headers", %{
      conn: conn,
      token: token,
      router: router
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "list_routers", "arguments" => %{}}
        })

      body = json_response(conn, 200)
      assert body["result"]["isError"] == false

      assert body["result"]["structuredContent"]["routers"] |> hd() |> Map.get("slug") ==
               router.slug
    end

    test "an unknown protocol version negotiates down rather than failing", %{
      conn: conn,
      token: token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "1999-01-01"}
        })

      # Naming the modern revision here would hand back something the client
      # cannot parse.
      assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-06-18"
    end

    test "a negotiated legacy version is served, not refused", %{conn: conn, token: token} do
      # Claude Code sends this header on every request after the handshake,
      # naming the version it negotiated. Reading presence as "must be modern"
      # rejected it one request after a successful initialize.
      conn = rpc(conn, token, "tools/list", nil, protocol_header: "2025-11-25")

      assert json_response(conn, 200)["result"]["tools"]
    end

    test "reports every version it serves when asked for one it does not", %{
      conn: conn,
      token: token
    } do
      conn = rpc(conn, token, "tools/list", nil, protocol_header: "1999-01-01")

      error = json_response(conn, 400)["error"]
      assert @version in error["data"]["supported"]
      assert "2025-11-25" in error["data"]["supported"]
      assert error["data"]["requested"] == "1999-01-01"
    end

    test "rejects a protocol version header that disagrees with the body", %{
      conn: conn,
      token: token
    } do
      params = %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2025-11-25"}}
      conn = rpc(conn, token, "tools/list", params)

      assert json_response(conn, 400)["error"]["code"] == -32_020
    end

    test "rejects an Mcp-Method header that disagrees with the body", %{conn: conn, token: token} do
      conn = rpc(conn, token, "tools/list", nil, method_header: "tools/call")

      error = json_response(conn, 400)["error"]
      assert error["code"] == -32_020
      assert error["message"] =~ "Mcp-Method"
    end

    test "rejects an Mcp-Name header that disagrees with the body", %{conn: conn, token: token} do
      params = %{"name" => "list_routers", "arguments" => %{}}
      conn = rpc(conn, token, "tools/call", params, name_header: "get_log")

      error = json_response(conn, 400)["error"]
      assert error["code"] == -32_020
      assert error["message"] =~ "Mcp-Name"
    end

    test "decodes a base64-wrapped Mcp-Name before comparing", %{conn: conn, token: token} do
      params = %{"name" => "list_routers", "arguments" => %{}}
      wrapped = "=?base64?" <> Base.encode64("list_routers") <> "?="

      conn = rpc(conn, token, "tools/call", params, name_header: wrapped)

      # A plain string comparison would call this a mismatch.
      assert json_response(conn, 200)["result"]["isError"] == false
    end

    test "a notification is accepted with 202 and no body", %{conn: conn, token: token} do
      conn = rpc(conn, token, "notifications/whatever", nil, id: nil)

      assert response(conn, 202) == ""
    end

    test "an unimplemented method is 404 with -32601 and says what exists", %{
      conn: conn,
      token: token
    } do
      conn = rpc(conn, token, "resources/list")

      error = json_response(conn, 404)["error"]
      assert error["code"] == -32_601
      assert "tools/call" in error["data"]["implemented"]
    end

    test "a foreign Origin is refused", %{conn: conn, token: token} do
      conn = rpc(conn, token, "tools/list", nil, origin: "https://evil.example")

      assert json_response(conn, 403)["error"]["message"] =~ "not allowed"
    end

    test "ping works", %{conn: conn, token: token} do
      assert json_response(rpc(conn, token, "ping"), 200)["result"]
    end
  end

  describe "tools/list" do
    test "lists every tool, marking the ones this token cannot use", %{
      conn: conn,
      user: user,
      router: router
    } do
      limited = AuthZFixtures.access_token(user, scopes: ["logs:read"])

      tools = json_response(rpc(conn, limited, "tools/list"), 200)["result"]["tools"]
      by_name = Map.new(tools, &{&1["name"], &1})

      # Hiding unusable tools would make a missing scope look like a missing
      # feature; naming the scope tells the agent what to ask its user for.
      assert by_name["list_logs"]["description"] =~ "requests this router served"
      refute by_name["list_logs"]["description"] =~ "UNAVAILABLE"
      assert by_name["create_eval"]["description"] =~ "UNAVAILABLE"
      assert by_name["create_eval"]["description"] =~ "evals:write"

      assert by_name["get_log"]["inputSchema"]["required"] == ["id"]
    end
  end

  describe "tools/call" do
    defp call_tool(conn, token, name, args \\ %{}) do
      rpc(conn, token, "tools/call", %{"name" => name, "arguments" => args})
    end

    test "an agent can retry only what failed, without re-running everything", %{
      conn: conn,
      token: token,
      user: user,
      router: router
    } do
      # The product gained cheap recovery — re-score a stored answer whose
      # judge call failed — and MCP had no way to reach it. run_eval is the
      # only other option and it re-generates every answer already paid for.
      key = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        DodoRouter.LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "m",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            })
        })

      {:ok, evaluation} =
        DodoRouter.Evaluations.create_evaluation(user, log, %{
          name: "Judge failed",
          criteria: "Be useful",
          judge_model: "fail-model",
          judge_provider_key_id: key.id,
          candidate_targets: [
            %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
          ],
          repetitions: 1
        })

      {:ok, _} = DodoRouter.Evaluations.run(user, evaluation)

      body = json_response(call_tool(conn, token, "get_eval", %{"id" => evaluation.id}), 200)
      payload = tool_json(body)

      # The stage is what tells an agent this is recoverable at all.
      assert [run] = payload["runs"]
      assert run["failure_stage"] == "judge"
      assert run["judged_by"] == "Key 1"
      assert payload["retryable"]["judge"] == 1

      evaluation
      |> Ecto.Changeset.change(judge_model: "judge-model")
      |> DodoRouter.Repo.update!()

      retried = json_response(call_tool(conn, token, "retry_eval", %{"id" => evaluation.id}), 200)
      assert retried["result"]["isError"] == false

      assert [%{"status" => "completed"}] =
               DodoRouter.Repo.all(
                 from(r in DodoRouter.Logs.EvaluationRun,
                   where: r.evaluation_id == ^evaluation.id and is_nil(r.superseded_at),
                   select: %{"status" => r.status}
                 )
               )
    end

    test "get_eval runs carry candidate_log_id, judge_log_id and criterion_scores", %{
      conn: conn,
      token: token,
      user: user,
      router: router
    } do
      # The guide (priv/agent/evals_guide.md) promises these ids so an agent
      # can pass them to get_log for the full answer or judge reasoning.
      key = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        DodoRouter.LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "m",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            })
        })

      {:ok, evaluation} =
        DodoRouter.Evaluations.create_evaluation(user, log, %{
          name: "Scored run",
          criteria: "Be useful",
          judge_model: "judge-model",
          judge_provider_key_id: key.id,
          candidate_targets: [
            %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
          ],
          repetitions: 1
        })

      {:ok, _} = DodoRouter.Evaluations.run(user, evaluation)

      body = json_response(call_tool(conn, token, "get_eval", %{"id" => evaluation.id}), 200)
      payload = tool_json(body)

      assert [run] = payload["runs"]
      assert run["candidate_log_id"]
      assert run["judge_log_id"]
      assert is_map(run["criterion_scores"])
    end

    test "run_eval refuses a judge key already known to be unusable", %{
      conn: conn,
      token: token,
      user: user,
      router: router
    } do
      key = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Spent"})
      DodoRouter.Providers.apply_health(key.id, :quota, "usage limit reached")

      log = DodoRouter.LogsFixtures.log_fixture(router)

      {:ok, evaluation} =
        DodoRouter.Evaluations.create_evaluation(user, log, %{
          name: "Doomed",
          criteria: "Be useful",
          judge_model: "judge-model",
          judge_provider_key_id: key.id,
          candidate_targets: []
        })

      body = json_response(call_tool(conn, token, "run_eval", %{"id" => evaluation.id}), 200)

      # An error the agent can act on, rather than a batch of answers
      # generated and discarded unscored.
      assert body["result"]["isError"] == true
      assert [%{"text" => text}] = body["result"]["content"]
      assert text =~ "Spent"
      assert text =~ "quota"
    end

    test "list_routers returns what the token reaches", %{
      conn: conn,
      token: token,
      router: router
    } do
      body = json_response(call_tool(conn, token, "list_routers"), 200)

      assert body["result"]["isError"] == false
      assert [%{"slug" => slug}] = tool_json(body)["routers"]
      assert slug == router.slug
      # Text content mirrors the structured payload for clients that only render text.
      assert [%{"type" => "text", "text" => text}] = body["result"]["content"]
      assert text =~ router.slug
    end

    test "the router argument is optional with one router and required with several", %{
      conn: conn,
      user: user,
      router: router
    } do
      LogsFixtures.log_fixture(router)

      # An OAuth token carries scopes but no router list, so reach is every
      # router its owner has — one here.
      one = AuthZFixtures.access_token(user)
      body = json_response(call_tool(conn, one, "list_logs"), 200)
      assert body["result"]["isError"] == false
      assert tool_json(body)["router"] == router.slug

      # A second router makes the argument ambiguous, and ambiguous is refused
      # rather than guessed — picking one silently would attribute results to a
      # router the caller never named.
      {_second, _key} = RoutersFixtures.router_fixture(user)
      many = AuthZFixtures.access_token(user)
      body = json_response(call_tool(conn, many, "list_logs"), 200)
      assert body["result"]["isError"]
      assert hd(body["result"]["content"])["text"] =~ "`router` is required"
    end

    test "a missing scope is an isError result, not a transport failure", %{
      conn: conn,
      user: user,
      router: router
    } do
      limited = AuthZFixtures.access_token(user, scopes: ["logs:read"])

      body = json_response(call_tool(conn, limited, "list_evals"), 200)

      # 200 with isError so the model reads the reason and can adapt; a bare
      # 403 would tell it only that something broke.
      assert body["result"]["isError"]
      assert hd(body["result"]["content"])["text"] =~ "evals:read"
    end

    test "get_log withholds bodies visibly without the scope", %{
      conn: conn,
      user: user,
      router: router
    } do
      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "secret"}]})
        })

      limited = AuthZFixtures.access_token(user, scopes: ["logs:read"])

      body = json_response(call_tool(conn, limited, "get_log", %{"id" => log.id}), 200)
      payload = tool_json(body)

      assert payload["total_tokens"] == 150
      assert payload["request_body"]["withheld"] =~ "logs:read_bodies"
      refute inspect(payload) =~ "secret"
    end

    test "eval targets say how each key bills, and advise against a plan judge", %{
      conn: conn,
      user: user,
      token: token
    } do
      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "metered"})

      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
        "provider_slug" => "test_provider_coding",
        "label" => "plan key"
      })

      body = json_response(call_tool(conn, token, "list_eval_targets"), 200)
      by_label = Map.new(tool_json(body)["targets"], &{&1["label"], &1})

      assert by_label["metered"]["billing"] == "metered"
      assert by_label["metered"]["judge_advice"] == nil

      # An agent picking a judge has no other way to know a plan key can be
      # refused for being outside its vendor's coding environment.
      assert by_label["plan key"]["billing"] == "subscription"
      assert by_label["plan key"]["judge_advice"] =~ "metered key for the judge"
    end

    test "create_eval includes the incumbent as a candidate by default", %{
      conn: conn,
      token: token,
      user: user,
      router: router
    } do
      incumbent_key =
        DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Incumbent"})

      other_key = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Other"})

      log_attrs = fn ->
        %{
          request_body:
            Jason.encode!(%{
              "model" => "m",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            }),
          final_model: "test-model",
          attempted_steps: [
            %{
              "status" => "success",
              "provider_key_id" => incumbent_key.id,
              "model" => "test-model"
            }
          ]
        }
      end

      base_args = fn log ->
        %{
          "request_log_id" => log.id,
          "name" => "Baseline check",
          "criteria" => "Be useful",
          "judge" => %{"provider_key_id" => other_key.id, "model" => "judge-model"},
          "candidates" => [
            %{"provider_key_id" => other_key.id, "model" => "challenger-model"}
          ]
        }
      end

      # A benchmark without the incumbent has numbers but no baseline — the
      # source log names what served it, so nobody should have to remember.
      log = DodoRouter.LogsFixtures.log_fixture(router, log_attrs.())
      body = json_response(call_tool(conn, token, "create_eval", base_args.(log)), 200)
      payload = tool_json(body)

      eval = DodoRouter.Evaluations.get_evaluation!(user, payload["id"])
      models = Enum.map(eval.candidate_targets, & &1["model"])
      assert "test-model" in models
      assert "challenger-model" in models

      # Opting out is explicit.
      log = DodoRouter.LogsFixtures.log_fixture(router, log_attrs.())

      body =
        json_response(
          call_tool(
            conn,
            token,
            "create_eval",
            Map.put(base_args.(log), "include_incumbent", false)
          ),
          200
        )

      eval = DodoRouter.Evaluations.get_evaluation!(user, tool_json(body)["id"])
      assert Enum.map(eval.candidate_targets, & &1["model"]) == ["challenger-model"]

      # Already naming the incumbent model (any key) adds nothing.
      log = DodoRouter.LogsFixtures.log_fixture(router, log_attrs.())

      args =
        Map.put(base_args.(log), "candidates", [
          %{"provider_key_id" => other_key.id, "model" => "test-model"}
        ])

      body = json_response(call_tool(conn, token, "create_eval", args), 200)
      eval = DodoRouter.Evaluations.get_evaluation!(user, tool_json(body)["id"])
      assert length(eval.candidate_targets) == 1
    end

    test "create_eval warns when the judge shares a provider key with a candidate", %{
      conn: conn,
      token: token,
      user: user,
      router: router
    } do
      key = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Shared Key"})
      other = DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "Solo Key"})

      log =
        DodoRouter.LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "m",
              "messages" => [%{"role" => "user", "content" => "hi"}]
            })
        })

      args = fn judge_key ->
        %{
          "request_log_id" => log.id,
          "name" => "Shared key check",
          "criteria" => "Be useful",
          "judge" => %{"provider_key_id" => judge_key.id, "model" => "judge-model"},
          "candidates" => [
            %{"provider_key_id" => key.id, "model" => "test-model"}
          ]
        }
      end

      # Judging and generating through one account spends the same quota
      # twice — knowable at creation, so it is said at creation.
      body = json_response(call_tool(conn, token, "create_eval", args.(key)), 200)
      payload = tool_json(body)
      assert payload["shared_judge_key_label"] == "Shared Key"
      assert Enum.any?(payload["warnings"], &(&1 =~ "quota"))

      body = json_response(call_tool(conn, token, "create_eval", args.(other)), 200)
      payload = tool_json(body)
      assert payload["shared_judge_key_label"] == nil
      assert payload["warnings"] in [nil, []]
    end

    test "eval targets filter by provider, model substring and limit", %{
      conn: conn,
      user: user,
      token: token
    } do
      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{"label" => "metered"})

      DodoRouter.ProvidersFixtures.provider_key_fixture(user, %{
        "provider_slug" => "test_provider_coding",
        "label" => "plan key"
      })

      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "test_provider",
          model_id: "alpha-large",
          display_name: "Alpha Large",
          input_price_per_million: Decimal.new("1.0"),
          output_price_per_million: Decimal.new("2.0")
        })

      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "test_provider",
          model_id: "beta-mini",
          display_name: "Beta Mini",
          input_price_per_million: Decimal.new("0.1"),
          output_price_per_million: Decimal.new("0.2")
        })

      # provider filter: only test_provider keys, not the coding-plan slug
      body =
        json_response(
          call_tool(conn, token, "list_eval_targets", %{"provider" => "test_provider"}),
          200
        )

      targets = tool_json(body)["targets"]
      assert Enum.all?(targets, &(&1["provider"] == "test_provider"))

      # model substring filter: prunes model lists and drops emptied targets
      body =
        json_response(call_tool(conn, token, "list_eval_targets", %{"model" => "ALPHA"}), 200)

      %{"targets" => filtered} = tool_json(body)
      assert filtered != []

      for target <- filtered, model <- target["models"] do
        assert model["id"] =~ "alpha" or model["display_name"] =~ "Alpha"
      end

      # limit caps the target list and says so
      body = json_response(call_tool(conn, token, "list_eval_targets", %{"limit" => 1}), 200)
      payload = tool_json(body)
      assert length(payload["targets"]) == 1
      assert payload["truncated"] == true
    end

    test "an unknown tool names the way to find the real ones", %{conn: conn, token: token} do
      body = json_response(call_tool(conn, token, "delete_everything"), 200)

      assert body["result"]["isError"]
      assert hd(body["result"]["content"])["text"] =~ "tools/list"
    end

    test "a log on another router is not reachable", %{conn: conn, user: user, token: token} do
      {other, _key} = RoutersFixtures.router_fixture(user)
      other_log = LogsFixtures.log_fixture(other)

      body = json_response(call_tool(conn, token, "get_log", %{"id" => other_log.id}), 200)

      assert body["result"]["isError"]
    end
  end

  describe "audit" do
    test "records the tool by name, under the mcp interface", %{
      conn: conn,
      user: user,
      token: token,
      router: router
    } do
      log = LogsFixtures.log_fixture(router, %{request_body: ~s({"messages":[]})})

      call_tool(conn, token, "get_log", %{"id" => log.id})

      assert [call] = Agents.list_calls(user)
      assert call.interface == "mcp"
      assert call.operation == "tools/call"
      assert call.tool == "get_log"
      assert call.target_type == "request_log"
      assert call.target_id == log.id
      assert call.returned_bodies
    end

    test "records a refused call with no credential", %{conn: conn} do
      conn
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", "tools/list")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert [call] = DodoRouter.Repo.all(DodoRouter.Agents.ApiCall)
      assert call.interface == "mcp"
      assert call.outcome == "denied"
    end
  end

  describe "credential separation" do
    test "a router's proxy key is not an agent credential", %{
      conn: conn,
      proxy_key: proxy_key
    } do
      # The regression the whole agent surface exists to prevent: a key that
      # sends traffic must not read it back. It was true when bearer agent
      # tokens guarded this and has to stay true now OAuth does.
      assert conn |> rpc(proxy_key, "tools/list") |> json_response(401)

      assert DodoRouter.Repo.all(DodoRouter.Agents.ApiCall)
             |> Enum.all?(&(&1.outcome == "denied"))
    end

    test "the proxy endpoints still take the proxy key", %{
      conn: conn,
      router: router,
      proxy_key: proxy_key
    } do
      # ...and the separation must not have broken what that key is for.
      assert conn
             |> put_req_header("authorization", "Bearer #{proxy_key}")
             |> get("/r/#{router.slug}/v1/models")
             |> json_response(200)
    end
  end

  describe "get_guide" do
    test "returns the workflow prose, with no scope required", %{conn: conn, user: user} do
      # The guide reached agents through the REST surface's GET /agent until
      # that was removed. Nothing else carries the part that decides whether
      # the numbers mean anything, so it has to be callable here — and by a
      # token holding nothing, since an agent reads it before asking for more.
      scopeless = AuthZFixtures.access_token(user, scopes: [])

      guide = call_tool(conn, scopeless, "get_guide") |> json_response(200) |> tool_json()

      assert guide["guide"] =~ "The incumbent is included for you"
      assert guide["guide"] =~ "rubric_feedback"
    end
  end
end
