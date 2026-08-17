defmodule DodoRouter.Logs.TokenAttribution do
  @moduledoc """
  Buckets a request's input tokens by what the context is made of, and by
  whether it sits in the cacheable prefix.

  The most useful number in context engineering is "tool results are 60% of
  your prompt tokens, and they sit after the cache breakpoint" — this module
  computes it from data every log row already stores.

  **Allocation, not tokenization.** No provider's tokenizer is available
  (Anthropic's for Claude 3+ is not public), so per-segment character counts
  are computed from the stored IR and the row's *billed* input total is
  allocated pro-rata. The buckets sum exactly to the billed number and the
  shares are accurate to within tokenizer variance; the field is named
  `allocated_tokens` so nobody mistakes it for tokenizer truth.

  Buckets, over the OpenAI-shaped IR (one parser covers every endpoint):

  * `system` — system messages
  * `tools` — the tool definitions array
  * `history` — user/assistant turns, including the assistant's tool calls
  * `tool_results` — `role: tool` messages, sub-bucketed `by_tool` via each
    result's `tool_call_id` matched back to the assistant call that produced
    it — which is how "80% of those are one Read" becomes visible
  * `file_contents` — file-shaped blobs *pasted by the user* (cat -n style
    line numbers, large fenced blocks, `<file>`/`<document>` tags). Content
    that arrived through a tool stays under `tool_results`/`by_tool`, which
    already names the tool that fetched it.

  Cache frontier, two mechanisms, one output:

  * Anthropic bodies keep their per-part `cache_control` markers in the IR —
    the frontier is the end of the last marked part (`"cache_control"`).
  * OpenAI-family caches by prefix implicitly — the row's `cache_read_tokens`
    converts to a character position via the same pro-rata ratio
    (`"cache_read"`).

  Each bucket's `cached_tokens` is the allocated share of its characters
  sitting before the frontier.
  """

  alias DodoRouter.Usage

  @buckets ~w(system tools history tool_results file_contents)

  @doc """
  Attributes a request's input tokens. Returns the stored-shape map, or nil
  when there is nothing honest to compute (no messages, no billed tokens).

  `opts`: `:partial` marks an attribution over a truncated request body —
  the shares are then of what survived storage, not of what was sent.
  """
  def attribute(request, prompt_tokens, cache_read_tokens, cache_write_tokens, opts \\ [])

  def attribute(%{"messages" => messages} = request, prompt, cache_read, cache_write, opts)
      when is_list(messages) and messages != [] do
    basis = Usage.total_input_tokens(prompt, cache_read, cache_write)

    if basis > 0 do
      segments = tool_segments(request) ++ message_segments(messages)
      compute(segments, basis, cache_read, opts)
    end
  end

  def attribute(_request, _prompt, _cache_read, _cache_write, _opts), do: nil

  @doc """
  Sums stored per-log attributions into one rollup — the per-session /
  per-router view. nil when there is nothing to merge. `cache_frontier`
  is not carried: rows can mix mechanisms, and a rollup's cached figures
  already say what mattered.
  """
  def merge([]), do: nil

  def merge(attributions) when is_list(attributions) do
    buckets =
      for name <- @buckets, into: %{} do
        summed =
          Enum.reduce(
            attributions,
            %{"chars" => 0, "allocated_tokens" => 0, "cached_tokens" => 0},
            fn attribution, acc ->
              bucket = get_in(attribution, ["buckets", name]) || %{}

              %{
                "chars" => acc["chars"] + (bucket["chars"] || 0),
                "allocated_tokens" => acc["allocated_tokens"] + (bucket["allocated_tokens"] || 0),
                "cached_tokens" => acc["cached_tokens"] + (bucket["cached_tokens"] || 0)
              }
            end
          )

        by_tool =
          attributions
          |> Enum.flat_map(fn attribution ->
            Map.to_list(get_in(attribution, ["buckets", name, "by_tool"]) || %{})
          end)
          |> Enum.reduce(%{}, fn {tool, tokens}, acc ->
            Map.update(acc, tool, tokens, &(&1 + tokens))
          end)

        summed = if by_tool == %{}, do: summed, else: Map.put(summed, "by_tool", by_tool)
        {name, summed}
      end

    %{
      "version" => 1,
      "rows" => length(attributions),
      "basis_tokens" => attributions |> Enum.map(&(&1["basis_tokens"] || 0)) |> Enum.sum(),
      "buckets" => buckets
    }
  end

  defp compute(segments, basis, cache_read, opts) do
    total_chars = segments |> Enum.map(& &1.chars) |> Enum.sum()

    if total_chars > 0 do
      {segments, frontier} = place_frontier(segments, total_chars, basis, cache_read)

      buckets =
        for name <- @buckets, into: %{} do
          in_bucket = Enum.filter(segments, &(&1.bucket == name))
          chars = in_bucket |> Enum.map(& &1.chars) |> Enum.sum()
          cached_chars = in_bucket |> Enum.map(& &1.cached_chars) |> Enum.sum()

          bucket = %{
            "chars" => chars,
            "allocated_tokens" => allocate(basis, chars, total_chars),
            "cached_tokens" => allocate(basis, cached_chars, total_chars)
          }

          bucket =
            case by_tool(in_bucket, basis, total_chars) do
              nil -> bucket
              by_tool -> Map.put(bucket, "by_tool", by_tool)
            end

          {name, bucket}
        end

      %{
        "version" => 1,
        "basis_tokens" => basis,
        "total_chars" => total_chars,
        "cache_frontier" => frontier,
        "buckets" => reconcile(buckets, basis)
      }
      |> then(fn attribution ->
        if opts[:partial], do: Map.put(attribution, "partial", true), else: attribution
      end)
    end
  end

  # Rounding each bucket independently can miss the billed total by a few
  # tokens; the difference lands on the largest bucket so the sum is exact —
  # numbers that don't add up teach people to distrust the whole panel.
  defp reconcile(buckets, basis) do
    allocated = buckets |> Enum.map(fn {_name, b} -> b["allocated_tokens"] end) |> Enum.sum()
    diff = basis - allocated

    if diff == 0 do
      buckets
    else
      {largest, _} = Enum.max_by(buckets, fn {_name, b} -> b["allocated_tokens"] end)
      update_in(buckets, [largest, "allocated_tokens"], &max(&1 + diff, 0))
    end
  end

  defp allocate(_basis, 0, _total_chars), do: 0
  defp allocate(basis, chars, total_chars), do: round(basis * chars / total_chars)

  # by_tool is reported only where it means something: a tool_results bucket
  # with at least one named tool.
  defp by_tool(segments, basis, total_chars) do
    named = Enum.filter(segments, &Map.has_key?(&1, :tool_name))

    if named == [] do
      nil
    else
      named
      |> Enum.group_by(& &1.tool_name)
      |> Map.new(fn {tool, segs} ->
        chars = segs |> Enum.map(& &1.chars) |> Enum.sum()
        {tool || "unknown", allocate(basis, chars, total_chars)}
      end)
    end
  end

  ## Segmentation

  defp tool_segments(%{"tools" => tools}) when is_list(tools) and tools != [] do
    [
      %{
        bucket: "tools",
        chars: tools |> Jason.encode!() |> String.length(),
        cache_control?: false
      }
    ]
  end

  defp tool_segments(_request), do: []

  defp message_segments(messages) do
    tool_names = tool_call_names(messages)

    Enum.flat_map(messages, fn message ->
      case message["role"] do
        "system" -> content_segments(message, "system")
        "tool" -> [tool_result_segment(message, tool_names)]
        role when role in ["user", "assistant"] -> turn_segments(message)
        _other -> content_segments(message, "history")
      end
    end)
  end

  # tool_call_id -> the function name the assistant called, so a result can
  # say which tool produced it.
  defp tool_call_names(messages) do
    for %{"role" => "assistant", "tool_calls" => calls} <- messages,
        is_list(calls),
        call <- calls,
        is_binary(call["id"]),
        into: %{} do
      {call["id"], get_in(call, ["function", "name"])}
    end
  end

  defp tool_result_segment(message, tool_names) do
    %{
      bucket: "tool_results",
      chars: content_chars(message["content"]),
      cache_control?: has_cache_control?(message["content"]),
      tool_name: Map.get(tool_names, message["tool_call_id"], "unknown")
    }
  end

  defp turn_segments(message) do
    base = content_segments(message, "history")

    case message["tool_calls"] do
      calls when is_list(calls) and calls != [] ->
        chars = calls |> Jason.encode!() |> String.length()
        base ++ [%{bucket: "history", chars: chars, cache_control?: false}]

      _ ->
        base
    end
  end

  # String content is one segment; a parts array yields one segment per part
  # so the cache frontier can land between parts, which is exactly where
  # cache_control puts it.
  defp content_segments(message, default_bucket) do
    case message["content"] do
      content when is_binary(content) ->
        [
          %{
            bucket: classify_text(content, default_bucket),
            chars: String.length(content),
            cache_control?: false
          }
        ]

      parts when is_list(parts) ->
        Enum.map(parts, fn part ->
          text = part_text(part)

          %{
            bucket: classify_text(text, default_bucket),
            chars: String.length(text),
            cache_control?: is_map(part) and Map.has_key?(part, "cache_control")
          }
        end)

      _ ->
        []
    end
  end

  defp part_text(%{"text" => text}) when is_binary(text), do: text
  defp part_text(part) when is_map(part), do: Jason.encode!(part)
  defp part_text(part) when is_binary(part), do: part
  defp part_text(_part), do: ""

  defp content_chars(content) when is_binary(content), do: String.length(content)

  defp content_chars(parts) when is_list(parts),
    do: parts |> Enum.map(&String.length(part_text(&1))) |> Enum.sum()

  defp content_chars(_content), do: 0

  defp has_cache_control?(parts) when is_list(parts),
    do: Enum.any?(parts, &(is_map(&1) and Map.has_key?(&1, "cache_control")))

  defp has_cache_control?(_content), do: false

  # File-shaped user content: cat -n style line numbers (the shape Read
  # output takes when pasted), a large fenced block, or explicit file tags.
  # Only user/system-side text is reclassified — content that arrived
  # through a tool already has a truer label.
  defp classify_text(text, "history") do
    if file_like?(text), do: "file_contents", else: "history"
  end

  defp classify_text(_text, bucket), do: bucket

  @line_numbered ~r/^\s{0,6}\d+[\t→|:]/
  defp file_like?(text) when byte_size(text) < 400, do: false

  defp file_like?(text) do
    numbered =
      text
      |> String.split("\n")
      |> Enum.count(&Regex.match?(@line_numbered, &1))

    cond do
      numbered >= 5 -> true
      String.contains?(text, "<file>") or String.contains?(text, "<document>") -> true
      large_fence?(text) -> true
      true -> false
    end
  end

  defp large_fence?(text) do
    case String.split(text, "```") do
      [_before, fenced | _rest] -> String.length(fenced) > 1_500
      _ -> false
    end
  end

  ## Cache frontier

  # Walks the segments in order accumulating character positions, then marks
  # how much of each segment sits before the frontier.
  defp place_frontier(segments, total_chars, basis, cache_read) do
    {positioned, _end} =
      Enum.map_reduce(segments, 0, fn segment, start ->
        {Map.put(segment, :start, start), start + segment.chars}
      end)

    frontier =
      cond do
        Enum.any?(positioned, & &1.cache_control?) ->
          last = positioned |> Enum.filter(& &1.cache_control?) |> List.last()
          {last.start + last.chars, "cache_control"}

        is_integer(cache_read) and cache_read > 0 ->
          {round(total_chars * cache_read / basis), "cache_read"}

        true ->
          nil
      end

    case frontier do
      nil ->
        {Enum.map(positioned, &Map.put(&1, :cached_chars, 0)), nil}

      {frontier_chars, mechanism} ->
        positioned =
          Enum.map(positioned, fn segment ->
            overlap = min(segment.chars, max(frontier_chars - segment.start, 0))
            Map.put(segment, :cached_chars, overlap)
          end)

        {positioned, mechanism}
    end
  end
end
