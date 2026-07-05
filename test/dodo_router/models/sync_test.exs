defmodule DodoRouter.Models.SyncTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Models.Sync

  describe "dodo_slug_for/1" do
    test "maps models.dev provider keys to adapter slugs" do
      # models.dev keys Moonshot under "moonshotai" — mapping it as
      # "moonshot" silently dropped every Kimi model from the catalog
      assert Sync.dodo_slug_for("moonshotai") == "moonshot"
      assert Sync.dodo_slug_for("zai") == "zai"
      assert Sync.dodo_slug_for("anthropic") == "anthropic"
    end

    test "coding plans map to their provider-key slugs" do
      assert Sync.dodo_slug_for("kimi-for-coding") == "moonshot_coding"
      assert Sync.dodo_slug_for("zai-coding-plan") == "zai_coding"
    end

    test "unmapped keys are dropped" do
      assert Sync.dodo_slug_for("moonshotai-cn") == nil
      assert Sync.dodo_slug_for("some-unknown-provider") == nil
    end
  end

  describe "missing_upstream_keys/1" do
    test "reports mapped keys absent from the models.dev payload" do
      payload = %{"anthropic" => %{}, "moonshotai" => %{}}

      missing = Sync.missing_upstream_keys(payload)

      assert "openai" in missing
      refute "anthropic" in missing
      refute "moonshotai" in missing
    end
  end
end
