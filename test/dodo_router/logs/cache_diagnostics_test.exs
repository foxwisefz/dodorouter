defmodule DodoRouter.Logs.CacheDiagnosticsTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Logs.CacheDiagnostics

  defp body do
    %{
      "model" => "model",
      "system" => "private instructions",
      "tools" => [%{"name" => "secret_tool", "input_schema" => %{"type" => "object"}}],
      "messages" => [%{"role" => "user", "content" => "private question"}]
    }
  end

  defp fingerprint(body, opts \\ []) do
    CacheDiagnostics.fingerprint(
      body,
      "router",
      Keyword.merge(
        [
          secret: "test secret",
          routing: {"provider", "key", "endpoint"},
          started_at_ms: 1000,
          finished_at_ms: 2000
        ],
        opts
      )
    )
  end

  defp log(fp, opts \\ []) do
    %{
      id: "previous",
      cache_fingerprint: fp,
      cache_read_tokens: Keyword.get(opts, :read, 0),
      cache_write_tokens: Keyword.get(opts, :write, 1000)
    }
  end

  test "fingerprints retain structure without prompt, tool names, or parameter values" do
    fp = fingerprint(body())
    encoded = Jason.encode!(fp)
    refute encoded =~ "private"
    refute encoded =~ "secret_tool"
    refute fp["routing_context"]["endpoint_hash"] == "endpoint"
    assert length(fp["messages"]) == 1
    assert fp["messages"] |> hd() |> Map.fetch!("role") == "user"
    assert fp != CacheDiagnostics.fingerprint(body(), "another-router", secret: "test secret")
  end

  test "reports changed message index without bodies, but appended messages are normal growth" do
    previous = log(fingerprint(body()))
    changed = put_in(body(), ["messages", Access.at(0), "content"], "edited")
    diagnosis = CacheDiagnostics.diagnose(log(fingerprint(changed)), previous)
    assert diagnosis["cause"] == "prefix_changed"

    assert diagnosis["first_change"] == %{
             "component" => "messages",
             "index" => 1,
             "role" => "user"
           }

    extended =
      Map.update!(body(), "messages", &(&1 ++ [%{"role" => "assistant", "content" => "answer"}]))

    assert CacheDiagnostics.diagnose(
             log(fingerprint(extended, started_at_ms: 3000, finished_at_ms: 4000)),
             previous
           )["cause"] == "provider_no_hit"
  end

  test "tool order changes are visible and parameter changes are not claimed as proven cache causes" do
    original = Map.put(body(), "tools", [%{"name" => "one"}, %{"name" => "two"}])
    changed = Map.update!(original, "tools", &Enum.reverse/1)

    assert CacheDiagnostics.diagnose(log(fingerprint(changed)), log(fingerprint(original)))[
             "first_change"
           ] ==
             %{"component" => "tools", "index" => 1}

    changed = Map.put(body(), "temperature", 0.2)
    diagnosis = CacheDiagnostics.diagnose(log(fingerprint(changed)), log(fingerprint(body())))
    assert diagnosis["cause"] == "unknown"
    assert diagnosis["first_change"]["component"] == "parameters"
  end

  test "missing usage, baseline, changed routing, or secret never imply a cache miss cause" do
    baseline = log(fingerprint(body()))

    assert CacheDiagnostics.diagnose(log(fingerprint(body()), read: nil), baseline)["observation"] ==
             "unreported"

    assert CacheDiagnostics.diagnose(baseline, nil)["cause"] == "unknown"

    for opts <- [
          [routing: {"p", "another-key", "endpoint"}],
          [secret: "rotated"]
        ] do
      assert CacheDiagnostics.diagnose(log(fingerprint(body(), opts)), baseline)["cause"] ==
               "unknown"
    end
  end

  test "explicit TTL and actual overlap are only likely explanations" do
    cached = Map.put(body(), "cache_control", %{"type" => "ephemeral", "ttl" => "5m"})
    previous = log(fingerprint(cached))
    expired = log(fingerprint(cached, started_at_ms: 400_000, finished_at_ms: 401_000))

    assert %{"cause" => "cache_expired", "confidence" => "likely"} =
             CacheDiagnostics.diagnose(expired, previous)

    never_cached = log(fingerprint(cached), read: 0, write: 0)
    assert CacheDiagnostics.diagnose(expired, never_cached)["cause"] == "provider_no_hit"
    overlap = log(fingerprint(cached, started_at_ms: 1500, finished_at_ms: 3000))

    assert %{"cause" => "parallel_race", "confidence" => "possible"} =
             CacheDiagnostics.diagnose(overlap, previous)
  end

  test "moving a breakpoint is distinguished from editing a message" do
    original =
      put_in(body(), ["messages", Access.at(0), "cache_control"], %{"type" => "ephemeral"})

    diagnosis = CacheDiagnostics.diagnose(log(fingerprint(body())), log(fingerprint(original)))
    assert diagnosis["first_change"]["component"] == "cache_control"
  end

  test "partial cache reads still expose changed prefix evidence without calling them a total miss" do
    changed = Map.put(body(), "system", "new system")

    result =
      CacheDiagnostics.diagnose(log(fingerprint(changed), read: 50), log(fingerprint(body())))

    assert result["observation"] == "cache_read"
    assert result["cause"] == "prefix_changed"
  end

  test "shortening history, mixed TTLs, type changes, and oversized evidence stay honest" do
    original = body()
    shortened = Map.put(original, "messages", [])
    result = CacheDiagnostics.diagnose(log(fingerprint(shortened)), log(fingerprint(original)))
    assert result["first_change"]["index"] == 1

    mixed =
      Map.put(original, "system", [
        %{"text" => "a", "cache_control" => %{"ttl" => "5m"}},
        %{"text" => "b", "cache_control" => %{"ttl" => "1h"}}
      ])

    assert fingerprint(mixed)["requested_ttl_seconds"] == nil

    refute fingerprint(Map.put(original, "temperature", 1))["parameters"] ==
             fingerprint(Map.put(original, "temperature", "1"))["parameters"]

    assert fingerprint(Map.put(original, "messages", List.duplicate(%{}, 4097))) == nil
  end

  test "a schema property called cache_control remains tool content" do
    original =
      put_in(body(), ["tools", Access.at(0), "input_schema"], %{
        "properties" => %{"cache_control" => %{"type" => "string"}}
      })

    changed =
      put_in(
        original,
        ["tools", Access.at(0), "input_schema", "properties", "cache_control", "type"],
        "number"
      )

    result = CacheDiagnostics.diagnose(log(fingerprint(changed)), log(fingerprint(original)))
    assert result["first_change"]["component"] == "tools"
  end

  test "MCP evidence exposes safe routing and settings comparisons, never cache key text" do
    original = Map.put(body(), "prompt_cache_key", "private-affinity-key")
    previous = log(fingerprint(original))
    changed = Map.put(original, "prompt_cache_key", "private-new-key")
    current = log(fingerprint(changed, started_at_ms: 3000, finished_at_ms: 4000))
    result = CacheDiagnostics.diagnose(current, previous)
    assert result["changes"]["cache_key"] == true
    assert result["changes"]["provider_key"] == false
    assert result["current"]["started_at_ms"] == 3000
    assert result["matched_messages"] == 1
    assert result["current"]["cache_key_hash"] != nil
    refute Jason.encode!(result) =~ "private"
  end
end
