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

    test "unmapped keys are dropped" do
      assert Sync.dodo_slug_for("moonshotai-cn") == nil
      assert Sync.dodo_slug_for("some-unknown-provider") == nil
    end
  end
end
