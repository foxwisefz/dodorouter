defmodule DodoRouter.Proxy.ResponsesRequestTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Proxy.FallbackChain
  alias DodoRouter.Proxy.ResponsesRequest
  alias DodoRouter.Proxy.Adapters.{Anthropic, OpenAICompatible, ResponsesAPI}
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouter.RoutersFixtures
  alias DodoRouterWeb.ResponsesFormat

  setup do
    user = AccountsFixtures.user_fixture()
    {router, _} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)

    step = %RoutingStep{
      id: Ecto.UUID.generate(),
      provider: "test_provider",
      model: "test-model",
      position: 0,
      provider_key: key,
      provider_key_id: key.id
    }

    %{router: router, step: step}
  end

  defp request do
    ResponsesFormat.to_openai_params(%{
      "model" => "default",
      "instructions" => "Build a mod",
      "input" => [
        %{"role" => "user", "content" => "Create a todo list"},
        %{
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Installing", "annotations" => []}]
        },
        %{
          "type" => "function_call",
          "call_id" => "put_mod:0",
          "name" => "put_mod",
          "arguments" => ~s({"content":"broken"})
        },
        %{
          "type" => "function_call_output",
          "call_id" => "put_mod:0",
          "output" => ~s({"error":"Generated Elixir has a syntax error","ok":false})
        }
      ],
      "tools" => [
        %{
          "type" => "function",
          "name" => "put_mod",
          "description" => "Install",
          "parameters" => %{"type" => "object"},
          "strict" => false
        }
      ],
      "tool_choice" => %{"type" => "function", "name" => "put_mod"}
    })
  end

  for stream <- [false, true] do
    @stream stream
    test "tool repair history survives the provider sanitizer (stream=#{stream})", %{
      router: router,
      step: step
    } do
      result =
        FallbackChain.execute(request(), [step], router.id,
          client_format: :responses,
          stream: @stream,
          send_chunk: fn _ -> :ok end
        )

      assert result.status == :success
      [attempt] = result.attempted_steps
      body = attempt.outbound_body
      assert [%{"role" => "system"}, %{"role" => "user"}, assistant, output] = body["messages"]
      assert assistant["role"] == "assistant"
      assert assistant["content"] == "Installing"

      assert assistant["tool_calls"] == [
               %{
                 "id" => "put_mod:0",
                 "type" => "function",
                 "function" => %{"name" => "put_mod", "arguments" => ~s({"content":"broken"})}
               }
             ]

      assert output == %{
               "role" => "tool",
               "tool_call_id" => "put_mod:0",
               "content" => ~s({"error":"Generated Elixir has a syntax error","ok":false})
             }

      assert [%{"type" => "function", "function" => function}] = body["tools"]
      assert function["name"] == "put_mod"
      assert function["strict"] == false
      assert body["tool_choice"] == %{"type" => "function", "function" => %{"name" => "put_mod"}}
    end
  end

  test "each fallback gets the translated history", %{router: router, step: step} do
    result =
      FallbackChain.execute(
        request(),
        [%{step | model: "fail-model"}, %{step | position: 1}],
        router.id,
        client_format: :responses
      )

    assert result.status == :fallback
    assert [first, second] = result.attempted_steps
    assert first.outbound_body["messages"] == second.outbound_body["messages"]
    assert List.last(second.outbound_body["messages"])["tool_call_id"] == "put_mod:0"
  end

  test "opaque items are refused before sending a corrupted upstream request", %{
    router: router,
    step: step
  } do
    for type <- ["reasoning", "additional_tools", "future_item"] do
      request = Map.put(request(), "messages", [%{"type" => type, "payload" => "must survive"}])
      result = FallbackChain.execute(request, [step], router.id, client_format: :responses)
      assert result.status == :error
      [attempt] = result.attempted_steps
      assert attempt.http_status == 400
      assert attempt.error_body =~ "unsupported_responses_item"
      assert attempt.error_body =~ type
      assert is_nil(attempt.outbound_body)
    end
  end

  test "parallel calls without preceding text become one assistant turn", %{
    router: router,
    step: step
  } do
    items = [
      %{"type" => "function_call", "call_id" => "a", "name" => "lookup", "arguments" => "{}"},
      %{"type" => "function_call", "call_id" => "b", "name" => "lookup", "arguments" => "{}"},
      %{
        "type" => "function_call_output",
        "call_id" => "b",
        "output" => [%{"type" => "input_text", "text" => "second"}]
      },
      %{"type" => "function_call_output", "call_id" => "a", "output" => "first"}
    ]

    request = ResponsesFormat.to_openai_params(%{"input" => items})
    result = FallbackChain.execute(request, [step], router.id, client_format: :responses)
    [attempt] = result.attempted_steps
    assert [assistant, second, first] = attempt.outbound_body["messages"]
    assert Enum.map(assistant["tool_calls"], & &1["id"]) == ["a", "b"]
    assert second == %{"role" => "tool", "tool_call_id" => "b", "content" => "second"}
    assert first["tool_call_id"] == "a"
  end

  test "the real Chat Completions builder receives complete repair history", %{step: step} do
    assert {:ok, translated} = ResponsesRequest.prepare(request(), :openai)
    body = OpenAICompatible.build_request_body(translated, %{step | model: "Kimi-k3"}, [])
    assert body["model"] == "Kimi-k3"
    assert Enum.all?(body["messages"], &is_binary(&1["role"]))
    assert List.last(body["messages"])["content"] =~ "syntax error"
    assert hd(body["tools"])["function"]["name"] == "put_mod"
  end

  test "translated repair history composes with the Anthropic builder", %{step: step} do
    assert {:ok, translated} = ResponsesRequest.prepare(request(), :anthropic)
    body = Anthropic.build_anthropic_request(translated, step)
    assert [_, assistant, output] = body["messages"]
    assert [%{"type" => "text", "text" => "Installing"}, call] = assistant["content"]

    assert call == %{
             "type" => "tool_use",
             "id" => "put_mod:0",
             "name" => "put_mod",
             "input" => %{"content" => "broken"}
           }

    assert [%{"type" => "tool_result", "tool_use_id" => "put_mod:0", "content" => content}] =
             output["content"]

    assert content =~ "syntax error"
    assert hd(body["tools"])["input_schema"] == %{"type" => "object"}
  end

  test "native Responses requests retain tool history and opaque items after a refused cross-format attempt",
       %{router: router, step: step} do
    opaque = %{
      "type" => "reasoning",
      "encrypted_content" => "opaque",
      "id" => "rs_1",
      "summary" => []
    }

    request = Map.update!(request(), "messages", &[opaque | &1])
    failed = FallbackChain.execute(request, [step], router.id, client_format: :responses)
    assert failed.status == :error

    assert {:ok, native} = ResponsesRequest.prepare(failed.request, :responses)
    assert native == request
    body = ResponsesAPI.build_request_body(native, step)
    assert hd(body["input"]) == opaque
    assert Enum.take(body["input"], -2) == Enum.take(request["messages"], -2)
    assert body["tools"] == request["tools"]
  end

  test "native built-in tools and non-text tool outputs are explicitly refused", %{
    router: router,
    step: step
  } do
    cases = [
      Map.put(request(), "tools", [%{"type" => "web_search"}]),
      Map.put(request(), "messages", [
        %{
          "type" => "function_call_output",
          "call_id" => "a",
          "output" => [%{"type" => "input_image", "image_url" => "data:image/png;base64,abc"}]
        }
      ])
    ]

    for request <- cases do
      result = FallbackChain.execute(request, [step], router.id, client_format: :responses)
      assert result.status == :error
      assert hd(result.attempted_steps).http_status == 400
      assert is_nil(hd(result.attempted_steps).outbound_body)
    end
  end

  test "user image input remains an image beside converted text", %{step: step} do
    request =
      ResponsesFormat.to_openai_params(%{
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "Inspect this"},
              %{
                "type" => "input_image",
                "image_url" => "data:image/png;base64,abc",
                "detail" => "high"
              }
            ]
          }
        ]
      })

    assert {:ok, translated} = ResponsesRequest.prepare(request, :openai)
    body = OpenAICompatible.build_request_body(translated, step, [])

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "Inspect this"},
                 %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/png;base64,abc", "detail" => "high"}
                 }
               ]
             }
           ] = body["messages"]
  end
end
