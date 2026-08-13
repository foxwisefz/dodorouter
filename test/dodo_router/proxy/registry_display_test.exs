defmodule DodoRouter.Proxy.Adapter.RegistryDisplayTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter.Registry

  describe "display_info/1" do
    test "names the key slug, not just the adapter behind it" do
      # A provider's pay-as-you-go API and its flat-rate coding plan are
      # separate credentials with separate quotas and separate base URLs.
      # Returning the adapter's display_name for both rendered two keys in
      # a picker as the identical string "Moonshot · Key 1" — the user could
      # not tell which one they were selecting.
      assert Registry.display_info("moonshot").name == "Moonshot"
      assert Registry.display_info("moonshot_coding").name == "Moonshot Coding"

      assert Registry.display_info("zai_standard").name == "z.ai Standard"
      assert Registry.display_info("zai_coding").name == "z.ai Coding"

      assert Registry.display_info("anthropic").name == "Anthropic API"
      assert Registry.display_info("anthropic_oauth").name =~ "Claude subscription"
    end

    test "agrees with the provider page, which already got this right" do
      # provider_info/0 has honoured key_display_names all along; the two
      # disagreeing is how the same key read differently on two pages.
      info = Registry.provider_info()

      for {slug, %{name: name}} <- info do
        assert Registry.display_info(slug).name == name,
               "display_info/1 and provider_info/0 disagree about #{slug}"
      end
    end

    test "still resolves the adapter for routing" do
      assert Registry.display_info("moonshot_coding").provider == "moonshot"
      assert Registry.display_info("zai_coding").provider == "zai"
    end

    test "an unknown slug is not a crash" do
      assert Registry.display_info("nope") == %{name: "Unknown", provider: nil}
    end
  end
end
