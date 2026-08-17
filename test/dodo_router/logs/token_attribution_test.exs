defmodule DodoRouter.Logs.TokenAttributionTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Logs.TokenAttribution

  # A Claude Code-shaped request: system with cache_control, tool defs, a
  # turn of history, an assistant tool call, its big result, a follow-up.
  defp request do
    %{
      "model" => "m",
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "Read",
            "description" => String.duplicate("reads a file ", 20),
            "parameters" => %{"type" => "object"}
          }
        }
      ],
      "messages" => [
        %{
          "role" => "system",
          "content" => [
            %{
              "type" => "text",
              "text" => String.duplicate("You are a careful assistant. ", 30),
              "cache_control" => %{"type" => "ephemeral"}
            }
          ]
        },
        %{"role" => "user", "content" => "please read the config"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "Read", "arguments" => ~s({"path":"config.ex"})}
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call_1",
          "content" => String.duplicate("defmodule Config do end\n", 60)
        },
        %{"role" => "user", "content" => "now summarize it"}
      ]
    }
  end

  test "buckets sum exactly to the billed input and name the tool behind results" do
    attribution = TokenAttribution.attribute(request(), 1000, 0, 0)

    buckets = attribution["buckets"]
    total = buckets |> Enum.map(fn {_name, b} -> b["allocated_tokens"] end) |> Enum.sum()
    assert total == 1000
    assert attribution["basis_tokens"] == 1000

    # The big Read result dominates, and by_tool says which tool fetched it.
    assert buckets["tool_results"]["allocated_tokens"] > buckets["history"]["allocated_tokens"]
    assert %{"Read" => read_tokens} = buckets["tool_results"]["by_tool"]
    assert read_tokens == buckets["tool_results"]["allocated_tokens"]

    assert buckets["system"]["allocated_tokens"] > 0
    assert buckets["tools"]["allocated_tokens"] > 0
  end

  test "anthropic cache_control marks the frontier: system cached, the tail not" do
    # Anthropic-style figures: prompt_tokens counts only uncached input, so
    # read + write exceed it and Usage infers separate reporting.
    attribution = TokenAttribution.attribute(request(), 200, 800, 100)

    assert attribution["cache_frontier"] == "cache_control"
    # basis = prompt + read + write.
    assert attribution["basis_tokens"] == 1100

    buckets = attribution["buckets"]
    assert buckets["system"]["cached_tokens"] == buckets["system"]["allocated_tokens"]
    # Everything after the marked system block sits outside the prefix.
    assert buckets["tool_results"]["cached_tokens"] == 0
    assert buckets["history"]["cached_tokens"] == 0
  end

  test "openai-family splits the prefix by cache_read depth without markers" do
    request = %{
      "messages" => [
        %{"role" => "system", "content" => String.duplicate("a", 500)},
        %{"role" => "user", "content" => String.duplicate("b", 500)}
      ]
    }

    # cached_tokens is a subset of prompt for OpenAI-family reporting; a
    # 500-token read over a 1000-token prompt reaches halfway.
    attribution = TokenAttribution.attribute(request, 1000, 500, 0)

    assert attribution["cache_frontier"] == "cache_read"
    assert attribution["basis_tokens"] == 1000

    buckets = attribution["buckets"]
    assert buckets["system"]["cached_tokens"] == buckets["system"]["allocated_tokens"]
    assert buckets["history"]["cached_tokens"] == 0
  end

  test "file-shaped user content is its own bucket; tool-fetched content is not" do
    file_text =
      1..30
      |> Enum.map(fn i -> "  #{i}\tdef line_#{i}, do: :ok" end)
      |> Enum.join("\n")

    request = %{
      "messages" => [
        %{"role" => "user", "content" => "here is the file:\n" <> file_text}
      ]
    }

    attribution = TokenAttribution.attribute(request, 100, 0, 0)
    assert attribution["buckets"]["file_contents"]["allocated_tokens"] > 0

    # The same bytes arriving as a tool result keep their truer label.
    as_tool_result = %{
      "messages" => [
        %{"role" => "user", "content" => "read it"},
        %{"role" => "tool", "tool_call_id" => "x", "content" => file_text}
      ]
    }

    attribution = TokenAttribution.attribute(as_tool_result, 100, 0, 0)
    assert attribution["buckets"]["file_contents"]["allocated_tokens"] == 0
    assert attribution["buckets"]["tool_results"]["allocated_tokens"] > 0
  end

  test "merge sums rows into a session rollup, by_tool included" do
    a = TokenAttribution.attribute(request(), 1000, 0, 0)
    b = TokenAttribution.attribute(request(), 500, 0, 0)

    merged = TokenAttribution.merge([a, b])

    assert merged["rows"] == 2
    assert merged["basis_tokens"] == 1500

    total =
      merged["buckets"]
      |> Enum.map(fn {_name, bucket} -> bucket["allocated_tokens"] end)
      |> Enum.sum()

    assert total == 1500

    read_total =
      a["buckets"]["tool_results"]["by_tool"]["Read"] +
        b["buckets"]["tool_results"]["by_tool"]["Read"]

    assert merged["buckets"]["tool_results"]["by_tool"]["Read"] == read_total
    assert TokenAttribution.merge([]) == nil
  end

  test "nothing honest to compute returns nil" do
    assert TokenAttribution.attribute(%{"messages" => []}, 100, 0, 0) == nil
    assert TokenAttribution.attribute(%{}, 100, 0, 0) == nil
    assert TokenAttribution.attribute(request(), 0, 0, 0) == nil
    assert TokenAttribution.attribute(request(), nil, nil, nil) == nil
  end

  test "a truncated body is marked partial rather than passed off as whole" do
    attribution = TokenAttribution.attribute(request(), 1000, 0, 0, partial: true)
    assert attribution["partial"] == true

    refute Map.has_key?(TokenAttribution.attribute(request(), 1000, 0, 0), "partial")
  end
end
