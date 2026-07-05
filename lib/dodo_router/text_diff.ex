defmodule DodoRouter.TextDiff do
  @moduledoc """
  Computes a word- or line-level diff between two pieces of text.

  The diff is computed with an escalating granularity ladder: word-level
  diffing is attempted first (best UX for small/medium text), falling back
  to line-level diffing for larger inputs, and finally giving up (`:none`
  granularity with a `:too_large` reason) for inputs that are too big to
  diff cheaply.
  """

  @type op :: :eq | :del | :ins
  @type segment :: {op(), String.t()}
  @type t :: %{
          granularity: :word | :line | :none,
          segments: [segment()],
          reason: nil | :empty | :one_sided | :too_large,
          stats: %{ins: non_neg_integer(), del: non_neg_integer(), eq: non_neg_integer()}
        }

  @word_regex ~r/\S+\s*/u

  @word_max_bytes 40_000
  @word_max_tokens 8_000
  @word_max_product 20_000_000

  @line_max_bytes 200_000
  @line_max_lines 2_000
  @line_max_product 4_000_000

  @doc """
  Prepares segments for display: whitespace-only `:eq` segments collapse to
  a single break and edge whitespace drops.

  When two texts share almost nothing, Myers aligns on the whitespace
  between paragraphs — rendered faithfully that's colored crumbs floating
  in voids of accumulated newlines. Display-only: unlike `diff/2` output,
  the result does NOT reconstruct the inputs.
  """
  @spec compact_for_display([segment()]) :: [segment()]
  def compact_for_display(segments) do
    segments
    |> Enum.map(fn
      {:eq, text} = segment ->
        cond do
          String.trim(text) != "" -> segment
          String.contains?(text, "\n") -> {:eq, "\n"}
          true -> {:eq, " "}
        end

      segment ->
        segment
    end)
    |> drop_edge_whitespace()
  end

  defp drop_edge_whitespace(segments) do
    drop = fn segs ->
      Enum.drop_while(segs, fn {op, text} -> op == :eq and String.trim(text) == "" end)
    end

    segments
    |> drop.()
    |> Enum.reverse()
    |> drop.()
    |> Enum.reverse()
  end

  @doc """
  Diffs two strings and returns a `t:t/0` describing the segments needed to
  turn `a` into `b`.

  Either argument may be `nil`, which is treated as an empty string.
  """
  @spec diff(String.t() | nil, String.t() | nil) :: t()
  def diff(a, b) do
    a = a || ""
    b = b || ""

    cond do
      a == "" and b == "" ->
        empty_result()

      a == "" or b == "" ->
        one_sided_result(a, b)

      true ->
        sized_diff(a, b)
    end
  end

  @doc """
  Fraction of tokens the two sides share (0.0..1.0), from a `diff/2` result.
  """
  @spec similarity(t()) :: float()
  def similarity(%{stats: %{eq: eq, ins: ins, del: del}}) do
    case eq + max(ins, del) do
      0 -> 1.0
      denominator -> eq / denominator
    end
  end

  defp empty_result do
    %{granularity: :none, segments: [], reason: :empty, stats: %{ins: 0, del: 0, eq: 0}}
  end

  defp one_sided_result(a, b) do
    if b == "" do
      %{
        granularity: :none,
        segments: [{:del, a}],
        reason: :one_sided,
        stats: %{ins: 0, del: length(word_tokens(a)), eq: 0}
      }
    else
      %{
        granularity: :none,
        segments: [{:ins, b}],
        reason: :one_sided,
        stats: %{ins: length(word_tokens(b)), del: 0, eq: 0}
      }
    end
  end

  defp sized_diff(a, b) do
    max_bytes = max(byte_size(a), byte_size(b))

    word_tokens_a = word_tokens(a)
    word_tokens_b = word_tokens(b)
    word_count_a = length(word_tokens_a)
    word_count_b = length(word_tokens_b)

    cond do
      max_bytes <= @word_max_bytes and word_count_a <= @word_max_tokens and
        word_count_b <= @word_max_tokens and
          word_count_a * word_count_b <= @word_max_product ->
        build_result(:word, word_tokens_a, word_tokens_b)

      true ->
        line_tokens_a = line_tokens(a)
        line_tokens_b = line_tokens(b)
        line_count_a = length(line_tokens_a)
        line_count_b = length(line_tokens_b)

        if max_bytes <= @line_max_bytes and line_count_a <= @line_max_lines and
             line_count_b <= @line_max_lines and
             line_count_a * line_count_b <= @line_max_product do
          build_result(:line, line_tokens_a, line_tokens_b)
        else
          %{granularity: :none, segments: [], reason: :too_large, stats: %{ins: 0, del: 0, eq: 0}}
        end
    end
  end

  defp word_tokens(text) do
    Regex.scan(@word_regex, text) |> List.flatten()
  end

  defp line_tokens(text) do
    text
    |> String.split(~r/(?<=\n)/)
    |> case do
      lines -> Enum.reject(lines, &(&1 == ""))
    end
  end

  defp build_result(granularity, tokens_a, tokens_b) do
    diffs = List.myers_difference(tokens_a, tokens_b)

    {ins, del, eq} =
      Enum.reduce(diffs, {0, 0, 0}, fn
        {:ins, tokens}, {ins, del, eq} -> {ins + length(tokens), del, eq}
        {:del, tokens}, {ins, del, eq} -> {ins, del + length(tokens), eq}
        {:eq, tokens}, {ins, del, eq} -> {ins, del, eq + length(tokens)}
      end)

    segments =
      diffs
      |> Enum.map(fn {op, tokens} -> {op, Enum.join(tokens)} end)
      |> Enum.reject(fn {_op, text} -> text == "" end)
      |> merge_consecutive()

    %{
      granularity: granularity,
      segments: segments,
      reason: nil,
      stats: %{ins: ins, del: del, eq: eq}
    }
  end

  defp merge_consecutive(segments) do
    Enum.reduce(segments, [], fn {op, text}, acc ->
      case acc do
        [{^op, prev_text} | rest] -> [{op, prev_text <> text} | rest]
        _ -> [{op, text} | acc]
      end
    end)
    |> Enum.reverse()
  end
end
