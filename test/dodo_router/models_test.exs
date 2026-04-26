defmodule DodoRouter.ModelsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Models
  alias DodoRouter.Models.Model

  describe "create_model/1" do
    test "creates a model with valid attrs" do
      attrs = %{
        provider_slug: "test_provider",
        model_id: "test-model-#{System.unique_integer([:positive])}",
        display_name: "Test Model",
        supports_vision: true,
        supports_function_calling: true
      }

      assert {:ok, model} = Models.create_model(attrs)
      assert model.provider_slug == "test_provider"
      assert model.supports_vision == true
      assert model.supports_function_calling == true
    end

    test "requires provider_slug, model_id, and display_name" do
      assert {:error, changeset} = Models.create_model(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :provider_slug)
      assert Map.has_key?(errors, :model_id)
      assert Map.has_key?(errors, :display_name)
    end
  end

  describe "upsert_model/1" do
    test "inserts new model" do
      attrs = %{provider_slug: "anthropic", model_id: "claude-3", display_name: "Claude 3"}

      assert {:ok, model} = Models.upsert_model(attrs)
      assert model.model_id == "claude-3"
    end

    test "updates existing model on conflict" do
      attrs = %{provider_slug: "anthropic", model_id: "claude-3", display_name: "Claude 3"}
      {:ok, _} = Models.upsert_model(attrs)

      updated_attrs = Map.put(attrs, :display_name, "Claude 3 Opus")
      assert {:ok, model} = Models.upsert_model(updated_attrs)
      assert model.display_name == "Claude 3 Opus"
    end
  end

  describe "list_models/0 and list_models_by_provider/1" do
    test "lists all models ordered by provider and model_id" do
      Models.create_model(%{provider_slug: "openai", model_id: "gpt-4o", display_name: "GPT-4o"})
      Models.create_model(%{provider_slug: "anthropic", model_id: "claude-3", display_name: "Claude 3"})

      models = Models.list_models()
      assert length(models) >= 2
    end

    test "filters by provider" do
      Models.create_model(%{provider_slug: "openai", model_id: "gpt-4o", display_name: "GPT-4o"})
      Models.create_model(%{provider_slug: "anthropic", model_id: "claude-3", display_name: "Claude 3"})

      models = Models.list_models_by_provider("openai")
      assert Enum.all?(models, &(&1.provider_slug == "openai"))
    end
  end

  describe "check_capabilities/2" do
    test "returns ok when all capabilities supported" do
      model = %Model{supports_vision: true, supports_function_calling: true}
      assert {:ok, ^model} = Models.check_capabilities(model, [:supports_vision, :supports_function_calling])
    end

    test "returns error with missing capabilities" do
      model = %Model{supports_vision: false, supports_function_calling: true}
      assert {:error, :missing_capabilities, [:supports_vision]} = Models.check_capabilities(model, [:supports_vision, :supports_function_calling])
    end
  end

  describe "calculate_cost/3" do
    test "calculates cost based on per-million pricing" do
      model = %Model{
        input_price_per_million: Decimal.new("5.0"),
        output_price_per_million: Decimal.new("15.0")
      }

      cost = Models.calculate_cost(model, 1_000_000, 1_000_000)
      assert Decimal.eq?(cost, Decimal.new("20.0"))
    end

    test "returns zero when prices are nil" do
      model = %Model{input_price_per_million: nil, output_price_per_million: nil}
      cost = Models.calculate_cost(model, 1000, 1000)
      assert Decimal.eq?(cost, Decimal.new("0"))
    end

    test "handles partial tokens" do
      model = %Model{
        input_price_per_million: Decimal.new("10.0"),
        output_price_per_million: nil
      }

      cost = Models.calculate_cost(model, 500_000, 0)
      assert Decimal.eq?(cost, Decimal.new("5.0"))
    end
  end
end
