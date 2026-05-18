defmodule DodoRouter.Proxy.Adapter.RegistryTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter.Registry

  describe "all_adapters/0" do
    test "returns all 11 providers keyed by slug" do
      adapters = Registry.all_adapters()

      assert Map.has_key?(adapters, "openai")
      assert Map.has_key?(adapters, "anthropic")
      assert Map.has_key?(adapters, "google")
      assert Map.has_key?(adapters, "groq")
      assert Map.has_key?(adapters, "mistral")
      assert Map.has_key?(adapters, "xai")
      assert Map.has_key?(adapters, "deepseek")
      assert Map.has_key?(adapters, "cohere")
      assert Map.has_key?(adapters, "moonshot")
      assert Map.has_key?(adapters, "zai")
      assert Map.has_key?(adapters, "test_provider")
      assert map_size(adapters) == 11
    end

    test "each adapter has required config fields" do
      for {slug, config} <- Registry.all_adapters() do
        assert config.slug == slug
        assert is_binary(config.display_name)
        assert is_atom(config.module)
        assert is_list(config.key_slugs)
        assert is_map(config.endpoints)
        assert is_list(config.models)
        assert is_binary(config.color)
        assert is_binary(config.short_description)
      end
    end
  end

  describe "providers/0" do
    test "returns sorted list of provider slugs" do
      providers = Registry.providers()

      assert providers == Enum.sort(providers)
      assert "openai" in providers
      assert "zai" in providers
      assert "test_provider" in providers
      assert length(providers) == 11
    end
  end

  describe "adapter_for/1" do
    test "returns correct module for known provider" do
      assert Registry.adapter_for("openai") == DodoRouter.Proxy.Adapters.OpenAI
      assert Registry.adapter_for("anthropic") == DodoRouter.Proxy.Adapters.Anthropic
      assert Registry.adapter_for("zai") == DodoRouter.Proxy.Adapters.Zai
    end

    test "returns nil for unknown provider" do
      assert Registry.adapter_for("nonexistent") == nil
    end
  end

  describe "provider_slugs/0" do
    test "returns flattened sorted key slugs from all adapters" do
      slugs = Registry.provider_slugs()

      assert "openai" in slugs
      assert "zai_standard" in slugs
      assert "zai_coding" in slugs
      assert "moonshot" in slugs
      assert "moonshot_coding" in slugs
      assert slugs == Enum.sort(slugs)
    end
  end

  describe "endpoint_for/1" do
    test "returns endpoint URL for known key slug" do
      assert Registry.endpoint_for("openai") == "https://api.openai.com/v1"
      assert Registry.endpoint_for("zai_standard") == "https://api.z.ai/api/paas/v4"
      assert Registry.endpoint_for("zai_coding") == "https://api.z.ai/api/coding/paas/v4"
    end

    test "returns nil for unknown key slug" do
      assert Registry.endpoint_for("nonexistent") == nil
    end
  end

  describe "display_info/1" do
    test "returns name and provider for known key slug" do
      info = Registry.display_info("openai")

      assert info.name == "OpenAI"
      assert info.provider == "openai"
    end

    test "returns info for zai key slugs" do
      info = Registry.display_info("zai_coding")
      assert info.name == "z.ai"
      assert info.provider == "zai"
    end

    test "returns Unknown for unknown key slug" do
      info = Registry.display_info("nonexistent")
      assert info == %{name: "Unknown", provider: nil}
    end
  end

  describe "available_models/1" do
    test "returns models for known provider" do
      models = Registry.available_models("openai")
      assert "gpt-4o" in models
      assert "o3" in models
    end

    test "returns empty list for unknown provider" do
      assert Registry.available_models("nonexistent") == []
    end
  end

  describe "to_key_slug/2" do
    test "maps provider and plan_type to matching key slug" do
      assert Registry.to_key_slug("zai", "coding") == "zai_coding"
      assert Registry.to_key_slug("zai", "standard") == "zai_standard"
    end

    test "falls back to first key slug when no match" do
      result = Registry.to_key_slug("openai", "coding")
      assert result == "openai"
    end

    test "returns provider when adapter not found" do
      assert Registry.to_key_slug("nonexistent", "standard") == "nonexistent"
    end
  end

  describe "adapter_provider/1" do
    test "extracts provider slug from key slug" do
      assert Registry.adapter_provider("openai") == "openai"
      assert Registry.adapter_provider("zai_coding") == "zai"
      assert Registry.adapter_provider("zai_standard") == "zai"
      assert Registry.adapter_provider("moonshot_coding") == "moonshot"
    end

    test "returns key slug when not found" do
      assert Registry.adapter_provider("nonexistent") == "nonexistent"
    end
  end

  describe "provider_info/0" do
    test "returns map keyed by key slug with required fields" do
      info = Registry.provider_info()

      assert Map.has_key?(info, "openai")
      assert Map.has_key?(info, "zai_standard")
      assert Map.has_key?(info, "zai_coding")

      for {_key_slug, data} <- info do
        assert Map.has_key?(data, :name)
        assert Map.has_key?(data, :short)
        assert Map.has_key?(data, :endpoint)
        assert Map.has_key?(data, :color)
      end
    end
  end
end
