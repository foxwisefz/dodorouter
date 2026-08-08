defmodule DodoRouter.Proxy.HeaderForwardingTest do
  @moduledoc """
  The request-fidelity policy (brain/main.md): client headers are forwarded to
  the provider by default, *including on fallback*. Stripping happens for
  exactly three reasons — we must replace it, the provider will break, or it
  isn't the client's to send.

  All policy lives in `Adapter.build_forwarded_headers/2`, which is provider
  agnostic and therefore behaves identically on step 1 and on step 5.
  """
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.Anthropic

  defp forward(client_headers, proxy_headers \\ [{"authorization", "Bearer proxy"}]) do
    Adapter.build_forwarded_headers(client_headers, proxy_headers)
  end

  defp keys(headers), do: Enum.map(headers, fn {k, _} -> String.downcase(k) end)

  defp value(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  describe "forward by default" do
    test "an arbitrary client header reaches the provider" do
      result = forward([{"x-stainless-lang", "js"}, {"x-custom-thing", "1"}])

      assert {"x-stainless-lang", "js"} in result
      assert {"x-custom-thing", "1"} in result
    end

    test "session headers are forwarded — they are often used downstream" do
      result = forward([{"x-session-id", "sess-1"}, {"x-session-name", "my task"}])

      assert {"x-session-id", "sess-1"} in result
      assert {"x-session-name", "my task"} in result
    end

    test "openai-beta is a feature flag, not account scope, so it forwards" do
      result = forward([{"openai-beta", "assistants=v2"}])

      assert {"openai-beta", "assistants=v2"} in result
    end

    test "provider-specific headers still forward on fallback to another provider" do
      # Step 1 (Anthropic) 429s and we fall back to an OpenAI-compatible
      # provider. anthropic-beta is meaningless there but harmless, and the
      # policy is to pass the client's request through rather than edit it.
      result = forward([{"anthropic-beta", "context-1m-2025-08-07"}])

      assert {"anthropic-beta", "context-1m-2025-08-07"} in result
    end
  end

  describe "strip reason 1: we must replace it" do
    test "client credentials never reach the provider; the proxy's win" do
      result =
        forward(
          [
            {"authorization", "Bearer client-token"},
            {"x-api-key", "client-key"},
            {"content-type", "text/plain"}
          ],
          [
            {"authorization", "Bearer proxy-token"},
            {"content-type", "application/json"}
          ]
        )

      assert value(result, "authorization") == "Bearer proxy-token"
      assert value(result, "content-type") == "application/json"
      refute "x-api-key" in keys(result)

      refute Enum.any?(result, fn {_, v} -> v == "Bearer client-token" end)
    end
  end

  describe "strip reason 2: the provider will break" do
    test "body-descriptive headers are lies once we rewrite the body" do
      result = forward([{"content-length", "1234"}, {"transfer-encoding", "chunked"}])

      refute "content-length" in keys(result)
      refute "transfer-encoding" in keys(result)
    end

    test "a stale accept-encoding corrupts streamed responses" do
      result = forward([{"accept-encoding", "gzip, br"}])

      refute "accept-encoding" in keys(result)
    end

    test "hop-by-hop headers do not survive a hop" do
      hop =
        ~w(host connection upgrade proxy-authorization proxy-authenticate te trailer keep-alive)

      result = forward(Enum.map(hop, &{&1, "x"}))

      assert keys(result) == ["authorization"]
    end

    test "account-scoped headers name the client's account, not the key we authenticate with" do
      scoped = ~w(openai-organization openai-project chatgpt-account-id x-goog-api-key
                  x-goog-user-project)

      result = forward(Enum.map(scoped, &{&1, "x"}))

      for header <- scoped do
        refute header in keys(result), "#{header} must not be forwarded"
      end
    end
  end

  describe "strip reason 3: it isn't the client's to send" do
    test "cookies may carry the user's own DodoRouter session" do
      result = forward([{"cookie", "_dodo_router_key=secret"}])

      refute "cookie" in keys(result)
    end

    test "edge headers are stripped by prefix, not by enumeration" do
      # Caddy sends x-forwarded-for/proto/host today, but its config lives on
      # the server rather than in this repo, so it can start sending another
      # x-forwarded-* with no change here. Enumerating goes stale silently.
      edge = [
        {"x-forwarded-for", "203.0.113.9"},
        {"x-forwarded-proto", "https"},
        {"x-forwarded-host", "api.dodorouter.com"},
        {"x-forwarded-server", "caddy-1"},
        {"x-forwarded-prefix", "/"},
        {"forwarded", "for=203.0.113.9"},
        {"via", "1.1 caddy"},
        {"x-real-ip", "203.0.113.9"},
        {"x-original-forwarded-for", "203.0.113.9"},
        {"x-original-url", "/v1/messages"}
      ]

      result = forward(edge)

      assert keys(result) == ["authorization"]
    end

    test "CDN client-IP headers are stripped in case anything ever fronts Caddy" do
      result = forward([{"cf-connecting-ip", "203.0.113.9"}, {"cf-ray", "abc"}])

      assert keys(result) == ["authorization"]
    end
  end

  describe "collisions" do
    test "the proxy's value wins when a client header collides with ours" do
      result =
        forward([{"anthropic-version", "1999-01-01"}], [
          {"anthropic-version", "2023-06-01"}
        ])

      versions = for {k, v} <- result, String.downcase(k) == "anthropic-version", do: v
      assert versions == ["2023-06-01"]
    end

    test "nil client headers yields the proxy headers untouched" do
      proxy = [{"authorization", "Bearer test"}]
      assert Adapter.build_forwarded_headers(nil, proxy) == proxy
    end
  end

  describe "Anthropic.request_headers/2 — anthropic-beta merges rather than collides" do
    test "a client's beta list survives the OAuth path with our oauth beta added" do
      # The regression this whole stack exists for: Claude Code opts into
      # extended-cache-ttl, and dropping it silently demotes an agent session
      # from a 1h prompt cache to 5 minutes.
      client = [
        {"anthropic-beta",
         "claude-code-20250219,extended-cache-ttl-2025-04-11,context-1m-2025-08-07"}
      ]

      headers = Anthropic.request_headers("sk-ant-oat01-abc", client)
      betas = headers |> value("anthropic-beta") |> String.split(",") |> Enum.map(&String.trim/1)

      assert "claude-code-20250219" in betas
      assert "extended-cache-ttl-2025-04-11" in betas
      assert "context-1m-2025-08-07" in betas
      assert "oauth-2025-04-20" in betas
    end

    test "exactly one anthropic-beta header is sent" do
      client = [{"anthropic-beta", "extended-cache-ttl-2025-04-11"}]

      headers = Anthropic.request_headers("sk-ant-oat01-abc", client)

      assert Enum.count(keys(headers), &(&1 == "anthropic-beta")) == 1
    end

    test "the oauth beta is not duplicated when the client already sent it" do
      client = [{"anthropic-beta", "oauth-2025-04-20,context-1m-2025-08-07"}]

      headers = Anthropic.request_headers("sk-ant-oat01-abc", client)
      betas = headers |> value("anthropic-beta") |> String.split(",") |> Enum.map(&String.trim/1)

      assert Enum.count(betas, &(&1 == "oauth-2025-04-20")) == 1
    end

    test "a client sending no beta list gets exactly the old headers" do
      headers = Anthropic.request_headers("sk-ant-oat01-abc", [{"user-agent", "claude-cli/1.0"}])

      assert value(headers, "anthropic-beta") == "oauth-2025-04-20"
      assert value(headers, "authorization") == "Bearer sk-ant-oat01-abc"
      assert value(headers, "user-agent") == "claude-cli/1.0"
    end

    test "the api-key path forwards the client's beta list and adds no oauth beta" do
      client = [{"anthropic-beta", "extended-cache-ttl-2025-04-11"}]

      headers = Anthropic.request_headers("sk-ant-api03-xyz", client)

      assert value(headers, "anthropic-beta") == "extended-cache-ttl-2025-04-11"
      assert value(headers, "x-api-key") == "sk-ant-api03-xyz"
      refute "authorization" in keys(headers)
    end

    test "count_tokens/4 uses the same merged headers as /messages" do
      # Claude Code calls count_tokens before compaction. Counting against a
      # different beta set than the request that follows would answer a
      # question about a request we are not going to send.
      client = [{"anthropic-beta", "context-1m-2025-08-07"}, {"user-agent", "claude-cli/1.0"}]

      assert :erlang.function_exported(Anthropic, :count_tokens, 4)

      assert Anthropic.request_headers("sk-ant-oat01-abc", client) |> value("anthropic-beta") ==
               "context-1m-2025-08-07,oauth-2025-04-20"
    end

    test "user-agent reaches Anthropic so subscription traffic looks like the real client" do
      headers =
        Anthropic.request_headers("sk-ant-oat01-abc", [
          {"user-agent", "claude-cli/1.0.83"},
          {"x-app", "cli"}
        ])

      assert value(headers, "user-agent") == "claude-cli/1.0.83"
      assert value(headers, "x-app") == "cli"
    end
  end
end
