defmodule DodoRouter.UsageTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Usage

  describe "Anthropic-style usage — prompt_tokens counts new input only" do
    test "cache_hit_pct counts cache reads in the denominator" do
      # Real log: 260 billed input tokens, 38_356 served from cache.
      # Dividing by prompt_tokens alone rendered this as 14752%.
      assert Usage.cache_hit_pct(260, 38_356, 0, 0) == 99.0
    end

    test "cache_hit_pct never exceeds 100%" do
      assert Usage.cache_hit_pct(6, 54_000, 0, 0) == 100.0
    end

    test "new input is prompt_tokens as-is" do
      assert Usage.new_input_tokens(260, 38_356, 0) == 260
      assert Usage.total_input_tokens(260, 38_356, 0) == 38_616
    end

    test "a cache write alone still marks the excluded convention" do
      # First request of a session: everything written, nothing read yet.
      assert Usage.new_input_tokens(260, 0, 38_356) == 260
      assert Usage.cache_hit_pct(260, 0, 38_356, 0) == 0.0
    end
  end

  describe "OpenAI-style usage — prompt_tokens already includes cache reads" do
    test "cache_hit_pct divides by prompt_tokens as-is" do
      assert Usage.cache_hit_pct(500, 400, 0, 0) == 80.0
    end

    test "a full cache hit is 100%" do
      assert Usage.cache_hit_pct(100, 100, 0, 0) == 100.0
    end

    test "new input subtracts the cached tokens" do
      assert Usage.new_input_tokens(500, 400, 0) == 100
      assert Usage.total_input_tokens(500, 400, 0) == 500
    end
  end

  describe "edges" do
    test "zero cache reads is 0%" do
      assert Usage.cache_hit_pct(500, 0, 0, 0) == 0.0
    end

    test "honors the precision argument" do
      assert Usage.cache_hit_pct(1_000, 2_000, 0, 1) == 66.7
      assert Usage.cache_hit_pct(1_000, 2_000, 0, 0) == 67.0
    end

    test "returns nil when there is no input at all" do
      assert Usage.cache_hit_pct(0, 0) == nil
      assert Usage.cache_hit_pct(nil, nil) == nil
    end

    test "treats nil as zero" do
      assert Usage.cache_hit_pct(100, nil, nil, 0) == 0.0
      assert Usage.cache_hit_pct(nil, 100, nil, 0) == 100.0
      assert Usage.new_input_tokens(nil, nil, nil) == 0
    end
  end
end
