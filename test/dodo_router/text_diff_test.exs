defmodule DodoRouter.TextDiffTest do
  use ExUnit.Case, async: true

  alias DodoRouter.TextDiff

  describe "granularity: :line option" do
    test "forces line mode on input that would auto-pick word mode" do
      a = "alpha beta\ngamma delta\n"
      b = "alpha BETA\ngamma delta\n"

      assert TextDiff.diff(a, b).granularity == :word
      assert TextDiff.diff(a, b, granularity: :line).granularity == :line
    end

    test "forced line mode still degrades past the size caps" do
      a = String.duplicate("x", 250_000)

      assert TextDiff.diff(a, a <> "y", granularity: :line).reason == :too_large
    end

    test "line-mode reconstruction invariants hold" do
      a = "{\n  \"query\": \"dodo\",\n  \"limit\": 5\n}"
      b = "{\n  \"query\": \"dodo router\",\n  \"limit\": 5\n}"

      result = TextDiff.diff(a, b, granularity: :line)
      assert result.granularity == :line

      original = for {op, text} <- result.segments, op in [:eq, :del], into: "", do: text
      replay = for {op, text} <- result.segments, op in [:eq, :ins], into: "", do: text
      assert original == a
      assert replay == b
    end
  end

  describe "compact_for_display/1" do
    test "squashes whitespace-only equal segments to a single break" do
      segments = [
        {:del, "Try:"},
        {:eq, "\n\n\n\n"},
        {:ins, "A few picks:"},
        {:eq, "  \n\n  "},
        {:del, "**Bluey**"}
      ]

      assert TextDiff.compact_for_display(segments) == [
               {:del, "Try:"},
               {:eq, "\n"},
               {:ins, "A few picks:"},
               {:eq, "\n"},
               {:del, "**Bluey**"}
             ]
    end

    test "whitespace-only equal segments without newlines become a single space" do
      assert TextDiff.compact_for_display([{:del, "a"}, {:eq, "   "}, {:ins, "b"}]) ==
               [{:del, "a"}, {:eq, " "}, {:ins, "b"}]
    end

    test "drops leading and trailing whitespace-only segments" do
      segments = [{:eq, "\n\n"}, {:del, "old"}, {:ins, "new"}, {:eq, "\n"}]

      assert TextDiff.compact_for_display(segments) == [{:del, "old"}, {:ins, "new"}]
    end

    test "leaves textual equal segments and change segments untouched" do
      segments = [{:eq, "shared intro\n\nmore shared"}, {:del, "a\n\nb"}, {:ins, "c"}]

      assert TextDiff.compact_for_display(segments) == segments
    end
  end

  describe "identical strings" do
    test "returns a single eq segment with zero stats" do
      text = "the quick brown fox"

      assert %{
               granularity: :word,
               segments: [{:eq, ^text}],
               reason: nil,
               stats: %{ins: 0, del: 0, eq: _}
             } = TextDiff.diff(text, text)
    end
  end

  describe "simple word replacement" do
    test "produces eq/del/ins/eq shape at word granularity" do
      result = TextDiff.diff("the quick brown fox", "the quick red fox")

      assert result.granularity == :word
      assert result.reason == nil

      ops = Enum.map(result.segments, &elem(&1, 0))
      assert ops == [:eq, :del, :ins, :eq]

      assert_reconstructs!(result, "the quick brown fox", "the quick red fox")
    end
  end

  describe "whitespace preservation" do
    test "reconstructs exactly with newlines, double spaces and tabs" do
      a = "line one\nline  two\tend\n"
      b = "line one\nline   two\tend\nextra line\n"

      result = TextDiff.diff(a, b)

      assert_reconstructs!(result, a, b)
    end
  end

  describe "unicode text" do
    test "round-trips emoji and accented characters" do
      a = "café résumé 🎉 naïve"
      b = "café résumé 🎊 naïve façade"

      result = TextDiff.diff(a, b)

      assert_reconstructs!(result, a, b)
    end
  end

  describe "nil and empty handling" do
    test "both nil returns :empty" do
      assert TextDiff.diff(nil, nil) == %{
               granularity: :none,
               segments: [],
               reason: :empty,
               stats: %{ins: 0, del: 0, eq: 0}
             }
    end

    test "both empty strings returns :empty" do
      assert TextDiff.diff("", "") == %{
               granularity: :none,
               segments: [],
               reason: :empty,
               stats: %{ins: 0, del: 0, eq: 0}
             }
    end

    test "nil vs value is treated as empty vs value" do
      assert TextDiff.diff(nil, "hello world") == TextDiff.diff("", "hello world")
    end
  end

  describe "one-sided diffs" do
    test "b empty produces a single del segment with del stats" do
      a = "one two three"

      result = TextDiff.diff(a, "")

      assert result == %{
               granularity: :none,
               segments: [{:del, a}],
               reason: :one_sided,
               stats: %{ins: 0, del: 3, eq: 0}
             }
    end

    test "a empty produces a single ins segment with ins stats" do
      b = "one two three four"

      result = TextDiff.diff("", b)

      assert result == %{
               granularity: :none,
               segments: [{:ins, b}],
               reason: :one_sided,
               stats: %{ins: 4, del: 0, eq: 0}
             }
    end

    test "nil a is treated the same as empty a" do
      assert TextDiff.diff(nil, "hello") == TextDiff.diff("", "hello")
    end
  end

  describe "consecutive segment merging" do
    test "does not emit two consecutive segments with the same op" do
      a = "a b c d e"
      b = "a x c y e"

      result = TextDiff.diff(a, b)

      ops = Enum.map(result.segments, &elem(&1, 0))

      refute Enum.any?(Enum.zip(ops, tl(ops)), fn {op1, op2} -> op1 == op2 end)

      assert_reconstructs!(result, a, b)
    end
  end

  describe "granularity ladder" do
    test "large word-count text with a small change falls back to :line" do
      a = String.duplicate("word ", 12_000)
      b = String.replace(a, "word word word", "word CHANGED word", global: false)

      result = TextDiff.diff(a, b)

      assert result.granularity == :line
      assert result.reason == nil
      assert_reconstructs!(result, a, b)
    end

    test "text larger than the line byte limit becomes :too_large" do
      a = String.duplicate("x", 250_000)
      b = a <> "y"

      result = TextDiff.diff(a, b)

      assert result == %{
               granularity: :none,
               segments: [],
               reason: :too_large,
               stats: %{ins: 0, del: 0, eq: 0}
             }
    end

    test "word product guard falls back to :line mode for single-line texts" do
      a = 1..5_000 |> Enum.map(&"a#{&1}") |> Enum.join(" ")
      b = 1..5_000 |> Enum.map(&"b#{&1}") |> Enum.join(" ")

      result = TextDiff.diff(a, b)

      assert result.granularity == :line
      assert_reconstructs!(result, a, b)
    end
  end

  describe "line mode reconstruction" do
    test "reconstructs exactly when a line is inserted" do
      a = Enum.map_join(1..10, "", fn n -> "line #{n}\n" end)
      b = Enum.map_join(1..10, "", fn n -> "line #{n}\n" end) <> "inserted line\n"

      # force line-mode by making the text large enough to skip word mode
      padding = String.duplicate("padword ", 10_000)
      a = padding <> a
      b = padding <> b

      result = TextDiff.diff(a, b)

      assert result.granularity == :line
      assert_reconstructs!(result, a, b)
    end
  end

  describe "stats correctness" do
    test "counts inserted and deleted tokens for a known diff" do
      a = "alpha beta gamma"
      b = "alpha delta epsilon gamma"

      result = TextDiff.diff(a, b)

      assert result.stats == %{ins: 2, del: 1, eq: 2}
    end
  end

  describe "similarity/1" do
    test "identical texts are fully similar" do
      assert TextDiff.similarity(TextDiff.diff("same text here", "same text here")) == 1.0
    end

    test "disjoint texts have zero similarity" do
      assert TextDiff.similarity(TextDiff.diff("alpha beta", "gamma delta epsilon")) == 0.0
    end

    test "partial overlap lands in between" do
      similarity = TextDiff.similarity(TextDiff.diff("the quick brown fox", "the quick red fox"))
      assert similarity == 3 / 4
    end

    test "empty diffs count as similar" do
      assert TextDiff.similarity(TextDiff.diff(nil, nil)) == 1.0
    end
  end

  defp assert_reconstructs!(result, a, b) do
    reconstructed_a =
      result.segments
      |> Enum.filter(fn {op, _} -> op in [:eq, :del] end)
      |> Enum.map_join(&elem(&1, 1))

    reconstructed_b =
      result.segments
      |> Enum.filter(fn {op, _} -> op in [:eq, :ins] end)
      |> Enum.map_join(&elem(&1, 1))

    assert reconstructed_a == a
    assert reconstructed_b == b
  end
end
