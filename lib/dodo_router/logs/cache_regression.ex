defmodule DodoRouter.Logs.CacheRegression do
  @moduledoc """
  Detects a prompt-cache prefix regression from a session's request logs.

  A broken cache prefix is silent — no error, no latency change, just a
  multiplied bill. The signature is the one diagnosed by hand in AGENTS.md's
  "Prompt Cache Fidelity Through Format Conversion": the cached read **pins**
  at the last stable breakpoint while the conversation keeps growing, so every
  turn re-pays full price for input that should have been read back for a
  tenth of it.

  This module is pure and I/O-free, in the style of
  `DodoRouter.Providers.KeyHealth.classify/3` — it takes the logs a caller
  already loaded and returns a verdict.

  ## What counts as comparable

  Two turns can only be compared when a cache could have carried between them,
  so the session is first cut into runs of consecutive turns that share a
  provider and model (caches are model-scoped — a switch legitimately starts
  over) and are no further apart than the longest cache lifetime Anthropic
  offers. Turns that logged no usage at all — a failed attempt — say nothing
  about the cache and are skipped without breaking the run.

  A session that interleaves two models therefore yields runs of one turn and
  is never flagged. That is deliberate: an alert nobody trusts is worse than
  no alert, and a fallback-thrashing session has a louder problem than its
  cache.

  ## What counts as a regression

  Within a run: a streak of consecutive turns that each fail to read back more
  than the turn before, long enough and over enough new input to rule out a
  conversation that simply is not growing. A read stuck at zero counts only
  when an earlier turn in the same run actually read from cache — a session
  that never cached has no working state to have regressed from, and saying
  otherwise would flag every provider that does not cache at all.
  """

  alias DodoRouter.Usage

  # Anthropic's longest cache TTL. A longer gap is an expiry, not a defect.
  @max_gap_seconds 60 * 60

  # Below this, a pinned read means nothing: there is not enough new input to
  # have created an entry from (the minimum cacheable prefix runs 512–4096
  # tokens depending on the model), so nothing was actually lost.
  @min_growth_tokens 2_048

  # One turn that fails to extend the prefix is noise; a run of them is a bug.
  @min_stalled_turns 3

  @type finding :: %{
          pinned_read: non_neg_integer(),
          diverged_at: struct(),
          through: struct(),
          turns: pos_integer(),
          uncached_growth: non_neg_integer()
        }

  @type verdict :: :healthy | :insufficient_data | {:regressed, finding()}

  @doc """
  Classifies a session's logs, oldest first.

  Returns `:insufficient_data` when there are fewer than
  `#{@min_stalled_turns}` turns carrying usage, `{:regressed, finding}` for the
  earliest stall found, and `:healthy` otherwise.
  """
  @spec classify([struct()]) :: verdict()
  def classify(logs) when is_list(logs) do
    turns = logs |> Enum.filter(&usable?/1) |> Enum.map(&measure/1)

    if length(turns) < @min_stalled_turns do
      :insufficient_data
    else
      turns
      |> comparable_runs()
      |> Enum.find_value(:healthy, &stall/1)
    end
  end

  # A turn with no usage recorded — an error, a dropped connection — is not
  # evidence either way.
  defp usable?(%{prompt_tokens: prompt, cache_read_tokens: read}),
    do: is_integer(prompt) and is_integer(read)

  defp usable?(_), do: false

  defp measure(log) do
    %{
      log: log,
      read: log.cache_read_tokens,
      # Providers disagree on whether `prompt_tokens` already contains the
      # cache figures; `Usage` infers the convention from the numbers, which is
      # the only thing that can tell them apart after the fact.
      input:
        Usage.total_input_tokens(log.prompt_tokens, log.cache_read_tokens, log.cache_write_tokens),
      key: {log.final_provider, log.final_model},
      at: log.inserted_at
    }
  end

  defp comparable_runs(turns) do
    turns
    |> Enum.chunk_while([], &chunk_turn/2, &close_run/1)
    |> Enum.reject(&(length(&1) < @min_stalled_turns))
  end

  defp chunk_turn(turn, []), do: {:cont, [turn]}

  defp chunk_turn(turn, [previous | _] = run) do
    if carries_cache?(previous, turn) do
      {:cont, [turn | run]}
    else
      {:cont, Enum.reverse(run), [turn]}
    end
  end

  defp close_run([]), do: {:cont, []}
  defp close_run(run), do: {:cont, Enum.reverse(run), []}

  defp carries_cache?(previous, turn) do
    turn.key == previous.key and gap_seconds(previous.at, turn.at) <= @max_gap_seconds
  end

  defp gap_seconds(%DateTime{} = from, %DateTime{} = to), do: abs(DateTime.diff(to, from))
  defp gap_seconds(_, _), do: 0

  # The earliest stall in a run, if any. A turn "extends" the cache when it
  # reads back more than the turn before it; a stall is a streak of turns that
  # do not.
  defp stall(run) do
    run
    |> mark()
    |> Enum.chunk_by(fn {_turn, extended?, _cached_before?} -> extended? end)
    |> Enum.find_value(fn [{_turn, extended?, _} | _] = streak ->
      if not extended? and regression?(streak), do: {:regressed, finding(streak)}
    end)
  end

  # Tags every turn after the first with whether it extended the cache, and
  # whether anything earlier *in this run* had read from cache at all. The
  # first turn is dropped: with nothing before it, it neither extends nor
  # stalls.
  defp mark([first | rest]) do
    {marks, _} =
      Enum.map_reduce(rest, {first, first.read > 0}, fn turn, {previous, cached_before?} ->
        {{turn, turn.read > previous.read, cached_before?},
         {turn, cached_before? or turn.read > 0}}
      end)

    marks
  end

  defp regression?([{first, _, cached_before?} | _] = streak) do
    {last, _, _} = List.last(streak)

    (first.read > 0 or cached_before?) and
      length(streak) >= @min_stalled_turns and
      growth(first, last) > @min_growth_tokens
  end

  defp finding([{first, _, _} | _] = streak) do
    {last, _, _} = List.last(streak)

    %{
      pinned_read: first.read,
      diverged_at: first.log,
      through: last.log,
      turns: length(streak),
      uncached_growth: growth(first, last)
    }
  end

  defp growth(from, to), do: max(0, to.input - from.input)
end
