defmodule DodoRouter.CacheCostTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Models
  alias DodoRouter.Models.Model

  describe "calculate_cost/4 with cache pricing" do
    test "calculates cost with cache read discount" do
      model = %Model{
        input_price_per_million: Decimal.new("3.0"),
        output_price_per_million: Decimal.new("15.0"),
        cache_read_price_per_million: Decimal.new("0.30"),
        cache_write_price_per_million: Decimal.new("3.75")
      }

      # 100 prompt tokens, 80 cached, 20 regular
      # 50 completion tokens
      cost = Models.calculate_cost(model, 100, 50, cache_read_tokens: 80, cache_write_tokens: 0)

      # Regular input: 20 tokens at $3/1M = $0.00006
      # Cache read: 80 tokens at $0.30/1M = $0.000024
      # Output: 50 tokens at $15/1M = $0.00075
      # Total: $0.000834
      assert Decimal.compare(cost, Decimal.new("0.000834")) == :eq
    end

    test "calculates cost with cache write surcharge" do
      model = %Model{
        input_price_per_million: Decimal.new("3.0"),
        output_price_per_million: Decimal.new("15.0"),
        cache_read_price_per_million: Decimal.new("0.30"),
        cache_write_price_per_million: Decimal.new("3.75")
      }

      # 100 prompt tokens, 0 cached read, 50 written to cache
      # regular input = 100 - 50 = 50
      # 50 completion tokens
      cost = Models.calculate_cost(model, 100, 50, cache_read_tokens: 0, cache_write_tokens: 50)

      # Regular input: 50 tokens at $3/1M = $0.00015
      # Cache write: 50 tokens at $3.75/1M = $0.0001875
      # Output: 50 tokens at $15/1M = $0.00075
      # Total: $0.0010875
      assert Decimal.compare(cost, Decimal.new("0.0010875")) == :eq
    end

    test "handles nil cache pricing (falls back to regular input pricing)" do
      model = %Model{
        input_price_per_million: Decimal.new("3.0"),
        output_price_per_million: Decimal.new("15.0"),
        cache_read_price_per_million: nil,
        cache_write_price_per_million: nil
      }

      cost = Models.calculate_cost(model, 100, 50, cache_read_tokens: 80, cache_write_tokens: 20)

      # With nil pricing, cache tokens cost $0, but they're still subtracted from regular input
      # Regular input: 100 - 80 - 20 = 0 tokens = $0
      # Cache read: $0 (nil pricing)
      # Cache write: $0 (nil pricing)
      # Output: 50 * 15/1M = $0.00075
      assert Decimal.compare(cost, Decimal.new("0.000750")) == :eq
    end

    test "handles zero cache tokens" do
      model = %Model{
        input_price_per_million: Decimal.new("3.0"),
        output_price_per_million: Decimal.new("15.0"),
        cache_read_price_per_million: Decimal.new("0.30"),
        cache_write_price_per_million: Decimal.new("3.75")
      }

      cost = Models.calculate_cost(model, 100, 50)

      # No cache tokens = standard pricing
      # Input: 100 * 3/1M = $0.0003
      # Output: 50 * 15/1M = $0.00075
      # Total: $0.00105
      assert Decimal.compare(cost, Decimal.new("0.00105")) == :eq
    end
  end
end
