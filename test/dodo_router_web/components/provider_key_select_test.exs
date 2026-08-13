defmodule DodoRouterWeb.ProviderKeySelectTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias DodoRouter.Providers.ProviderKey
  alias DodoRouterWeb.ProviderComponents

  defp key(attrs) do
    struct!(
      %ProviderKey{
        id: Ecto.UUID.generate(),
        label: "Key 1",
        key_hint: "sk-••••Ly1",
        provider_slug: "moonshot"
      },
      attrs
    )
  end

  describe "provider_key_option_label/1" do
    test "distinguishes two keys that differ only by plan" do
      # This is the whole reason the helper exists: "Moonshot · Key 1"
      # appeared twice in one dropdown, once for the metered API and once
      # for the coding plan, with nothing to choose between them.
      api = key(%{provider_slug: "moonshot", label: "Key 1"})
      plan = key(%{provider_slug: "moonshot_coding", label: "Key 1"})

      api_label = ProviderComponents.provider_key_option_label(api)
      plan_label = ProviderComponents.provider_key_option_label(plan)

      assert api_label =~ "Moonshot"
      assert plan_label =~ "Moonshot Coding"
      refute api_label == plan_label
    end

    test "carries the key hint, so two keys of one plan are also distinct" do
      first = key(%{label: "Key 1", key_hint: "sk-••••aaa"})
      second = key(%{label: "Key 1", key_hint: "sk-••••bbb"})

      refute ProviderComponents.provider_key_option_label(first) ==
               ProviderComponents.provider_key_option_label(second)
    end

    test "says when a key is known to be unusable" do
      # A picker that offers an exhausted key without saying so is how a
      # benchmark gets started against a credential that cannot work.
      exhausted = key(%{status: "quota_exceeded"})

      assert ProviderComponents.provider_key_option_label(exhausted) =~ "out of quota"
    end
  end

  describe "provider_key_select/1" do
    test "renders one option per key, with the shared label" do
      keys = [
        key(%{provider_slug: "moonshot", label: "Key 1"}),
        key(%{provider_slug: "moonshot_coding", label: "Key 1"})
      ]

      html =
        render_component(&ProviderComponents.provider_key_select/1,
          id: "judge-key",
          name: "evaluation[judge_key]",
          value: nil,
          prompt: "Choose provider key",
          keys: keys
        )

      assert html =~ "Choose provider key"
      assert html =~ "Moonshot Coding"
      assert html =~ ~s(name="evaluation[judge_key]")
    end

    test "marks the selected key" do
      [first, second] = [key(%{label: "Key 1"}), key(%{label: "Key 2"})]

      html =
        render_component(&ProviderComponents.provider_key_select/1,
          id: "judge-key",
          name: "k",
          value: second.id,
          keys: [first, second]
        )

      assert html =~ ~s(value="#{second.id}" selected)
    end
  end
end
