defmodule DodoRouter.Models.SyncMirrorTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Models
  alias DodoRouter.Models.Sync

  setup do
    {:ok, _} =
      Models.create_model(%{
        provider_slug: "anthropic",
        model_id: "claude-opus-4-5",
        display_name: "Claude Opus 4.5",
        input_price_per_million: Decimal.new("5.0"),
        output_price_per_million: Decimal.new("25.0"),
        max_input_tokens: 200_000,
        reasoning_efforts: ["low", "high"]
      })

    {:ok, _} =
      Models.create_model(%{
        provider_slug: "openai",
        model_id: "gpt-5.3-codex",
        display_name: "GPT-5.3 Codex",
        input_price_per_million: Decimal.new("1.25"),
        output_price_per_million: Decimal.new("10.0")
      })

    {:ok, _} =
      Models.create_model(%{
        provider_slug: "openai",
        model_id: "gpt-5.2",
        display_name: "GPT-5.2",
        input_price_per_million: Decimal.new("1.25"),
        output_price_per_million: Decimal.new("10.0")
      })

    :ok
  end

  test "mirrors claude models into anthropic_oauth with zero pricing, keeping metadata" do
    {:ok, count} = Sync.mirror_subscription_catalogs()
    assert count >= 2

    [mirrored] = Models.list_models_by_provider("anthropic_oauth")

    assert mirrored.model_id == "claude-opus-4-5"
    assert mirrored.display_name == "Claude Opus 4.5"
    assert Decimal.eq?(mirrored.input_price_per_million, 0)
    assert Decimal.eq?(mirrored.output_price_per_million, 0)
    assert mirrored.max_input_tokens == 200_000
    assert mirrored.reasoning_efforts == ["low", "high"]
  end

  test "mirrors only codex models into openai-codex" do
    {:ok, _count} = Sync.mirror_subscription_catalogs()

    codex_ids = "openai-codex" |> Models.list_models_by_provider() |> Enum.map(& &1.model_id)

    assert "gpt-5.3-codex" in codex_ids
    refute "gpt-5.2" in codex_ids
  end

  test "re-running the mirror is idempotent" do
    {:ok, _} = Sync.mirror_subscription_catalogs()
    {:ok, _} = Sync.mirror_subscription_catalogs()

    assert length(Models.list_models_by_provider("anthropic_oauth")) == 1
  end
end
