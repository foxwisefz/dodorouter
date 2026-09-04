defmodule DodoRouter.PlaygroundTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Logs
  alias DodoRouter.Models
  alias DodoRouter.Playground
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  @image %{data_url: "data:image/png;base64,iVBORw0KGgo=", name: "dot.png"}

  setup do
    user = AccountsFixtures.user_fixture()
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    %{user: user, router: router, key: key}
  end

  describe "build_request/3" do
    test "a text-only user turn is a plain string, a system prompt leads" do
      turns = [%{role: :user, text: "hi", images: []}]

      assert Playground.build_request(turns, "m", system_prompt: "Be terse.") == %{
               "model" => "m",
               "messages" => [
                 %{"role" => "system", "content" => "Be terse."},
                 %{"role" => "user", "content" => "hi"}
               ]
             }
    end

    test "a blank system prompt adds no system message" do
      turns = [%{role: :user, text: "hi", images: []}]

      assert %{"messages" => [%{"role" => "user"}]} =
               Playground.build_request(turns, "m", system_prompt: "  ")
    end

    test "images ride as image_url parts next to the text" do
      turns = [%{role: :user, text: "What is this?", images: [@image]}]
      url = @image.data_url

      assert %{
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "text", "text" => "What is this?"},
                     %{"type" => "image_url", "image_url" => %{"url" => ^url}}
                   ]
                 }
               ]
             } = Playground.build_request(turns, "m")
    end

    test "completed assistant turns continue the thread, failed ones do not" do
      turns = [
        %{role: :user, text: "one", images: []},
        %{role: :assistant, status: :done, text: "answer one"},
        %{role: :user, text: "two", images: []},
        %{role: :assistant, status: :error, text: ""},
        %{role: :user, text: "three", images: []}
      ]

      assert %{"messages" => messages} = Playground.build_request(turns, "m")

      assert Enum.map(messages, &{&1["role"], &1["content"]}) == [
               {"user", "one"},
               {"assistant", "answer one"},
               {"user", "two"},
               {"user", "three"}
             ]
    end
  end

  describe "send_turn/5" do
    test "answers and files the turn as playground traffic", %{
      user: user,
      router: router,
      key: key
    } do
      request = Playground.build_request([%{role: :user, text: "hi", images: []}], "test-model")
      target = %{provider_key_id: key.id, model: "test-model", reasoning_effort: ""}

      assert {:ok, reply} = Playground.send_turn(user, router, target, request)
      assert reply.text == "Hello from test-model"
      assert reply.model == "test-model"
      assert reply.prompt_tokens == 10
      assert reply.completion_tokens == 5

      assert %Logs.RequestLog{traffic_type: "playground", status: "success"} = reply.log
      assert reply.log.router_id == router.id

      # Playground turns are not the router's traffic
      assert Logs.list_logs(router) == []
    end

    test "streams deltas to the caller before returning the logged answer", %{
      user: user,
      router: router,
      key: key
    } do
      request = Playground.build_request([%{role: :user, text: "hi", images: []}], "test-model")
      target = %{provider_key_id: key.id, model: "test-model"}
      pid = self()

      assert {:ok, reply} =
               Playground.send_turn(user, router, target, request,
                 on_delta: fn delta -> send(pid, {:delta, delta}) end
               )

      deltas = collect_deltas([])
      assert Enum.map_join(deltas, "", & &1.content) == "Hello from test-model "
      assert reply.text == "Hello from test-model"
      assert reply.log.traffic_type == "playground"
    end

    test "a provider failure comes back as a message with its log", %{
      user: user,
      router: router,
      key: key
    } do
      request = Playground.build_request([%{role: :user, text: "hi", images: []}], "fail-model")
      target = %{provider_key_id: key.id, model: "fail-model"}

      assert {:error, failure} = Playground.send_turn(user, router, target, request)
      assert failure.message =~ "Test Provider"
      assert failure.model == "fail-model"
      assert %Logs.RequestLog{status: "error", traffic_type: "playground"} = failure.log
    end

    test "an image reaches the provider as an image part", %{
      user: user,
      router: router,
      key: key
    } do
      turns = [%{role: :user, text: "Describe", images: [@image]}]
      request = Playground.build_request(turns, "test-model")
      target = %{provider_key_id: key.id, model: "test-model"}

      assert {:ok, reply} = Playground.send_turn(user, router, target, request)

      [attempt] = reply.log.attempted_steps

      assert %{"messages" => [%{"content" => [_text, %{"type" => "image_url"}]}]} =
               Jason.decode!(attempt["outbound_body"])
    end

    test "refuses a blank model without dispatching", %{user: user, router: router, key: key} do
      request = Playground.build_request([%{role: :user, text: "hi", images: []}], "")

      assert {:error, %{message: message, log: nil}} =
               Playground.send_turn(user, router, %{provider_key_id: key.id, model: ""}, request)

      assert message =~ "model"
    end

    test "refuses a key that is not the user's", %{user: user, router: router} do
      other_key = ProvidersFixtures.provider_key_fixture(AccountsFixtures.user_fixture())
      request = Playground.build_request([%{role: :user, text: "hi", images: []}], "test-model")

      assert {:error, %{log: nil}} =
               Playground.send_turn(
                 user,
                 router,
                 %{provider_key_id: other_key.id, model: "test-model"},
                 request
               )
    end
  end

  describe "model_facts/2" do
    test "reads the catalog row for the key's provider", %{key: key} do
      {:ok, _model} =
        Models.upsert_model(%{
          provider_slug: "test_provider",
          model_id: "test-model",
          display_name: "Test Model",
          supports_vision: false
        })

      facts = Playground.model_facts(key, "test-model")
      assert facts.display_name == "Test Model"
      assert Playground.rejects_images?(facts)
      refute Playground.rejects_images?(nil)
      assert Playground.model_facts(key, "unknown-model") == nil
    end
  end

  defp collect_deltas(acc) do
    receive do
      {:delta, delta} -> collect_deltas([delta | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
