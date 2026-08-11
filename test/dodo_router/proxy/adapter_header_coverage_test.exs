defmodule DodoRouter.Proxy.AdapterHeaderCoverageTest do
  @moduledoc """
  The request-fidelity policy says client headers reach the provider by
  default, *including on fallback*. `Adapter.build_forwarded_headers/2` is the
  single place that policy lives — but a policy only applies where it is
  called, and for a while it was called by three adapters out of twelve while
  four more accepted `client_headers` and dropped them on the floor.

  Every adapter that makes an upstream HTTP request therefore exposes
  `request_headers/2`, and this test walks the registry so a new adapter cannot
  be added without deciding what it does with the client's headers.
  """
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.Adapter.Registry

  # Adapters that legitimately cannot forward client headers, with the reason.
  # Empty today; the branch exists so a future adapter with a real constraint
  # has somewhere to state it instead of quietly failing the sweep.
  @cannot_forward %{}

  defp adapters_under_test do
    Registry.registered_modules() -- Map.keys(@cannot_forward)
  end

  defp keys(headers), do: Enum.map(headers, fn {k, _} -> String.downcase(to_string(k)) end)

  defp value(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name, do: v end)
  end

  describe "every adapter forwards benign client headers" do
    test "a client trace header reaches the outbound header list" do
      for module <- adapters_under_test() do
        headers = module.request_headers("test-api-key", [{"x-client-trace", "abc123"}])

        assert {"x-client-trace", "abc123"} in headers,
               "#{inspect(module)} dropped the client's x-client-trace header"
      end
    end

    test "the client's user-agent survives, so upstream sees the real client" do
      for module <- adapters_under_test() do
        headers = module.request_headers("test-api-key", [{"user-agent", "claude-cli/1.0.83"}])

        assert value(headers, "user-agent") == "claude-cli/1.0.83",
               "#{inspect(module)} dropped the client's user-agent"
      end
    end

    test "the three strip reasons still apply everywhere" do
      hostile = [
        # 1. we must replace it
        {"authorization", "Bearer client-token"},
        {"x-api-key", "client-key"},
        # 2. the provider will break
        {"content-length", "1234"},
        {"accept-encoding", "gzip"},
        {"host", "api.dodorouter.com"},
        {"openai-organization", "org-client"},
        {"chatgpt-account-id", "acct-client"},
        # 3. not the client's to send
        {"cookie", "_dodo_router_key=secret"},
        {"x-forwarded-for", "203.0.113.9"}
      ]

      for module <- adapters_under_test() do
        headers = module.request_headers("test-api-key", hostile)
        header_keys = keys(headers)

        for stripped <- ~w(content-length accept-encoding host
                           openai-organization cookie x-forwarded-for) do
          refute stripped in header_keys, "#{inspect(module)} forwarded #{stripped}"
        end

        # `authorization` and `x-api-key` may legitimately appear — Anthropic
        # authenticates with `x-api-key` — but never carrying the client's value.
        for leaked <- ["Bearer client-token", "client-key", "acct-client"] do
          refute Enum.any?(headers, fn {_, v} -> v == leaked end),
                 "#{inspect(module)} forwarded the client's credential #{leaked}"
        end
      end
    end

    test "nil client headers are tolerated by every adapter" do
      for module <- adapters_under_test() do
        assert is_list(module.request_headers("test-api-key", nil)),
               "#{inspect(module)} could not build headers without client headers"
      end
    end
  end

  describe "registry coverage" do
    test "every registered adapter declares the wire format it builds" do
      # Passthrough of untranslated client fields turns on when a step's format
      # matches the client's, so a new adapter must state which format it
      # speaks rather than inherit one by accident. Declared, not inferred from
      # endpoint_path: the path is a URL detail that only happens to correlate.
      known = ~w(openai anthropic responses gemini)a

      for module <- Registry.registered_modules() do
        format = Registry.request_format(module)

        assert format in known,
               "#{inspect(module)} declares request_format: #{inspect(format)} — " <>
                 "expected one of #{inspect(known)}"
      end
    end

    test "the format is what the endpoint path implies" do
      # Not the source of truth — a cross-check that the two never silently
      # disagree, since a mismatch means either the wrong passthrough behavior
      # or a stale path.
      implied = %{
        "/messages" => :anthropic,
        "/responses" => :responses,
        "/chat/completions" => :openai
      }

      for module <- Registry.registered_modules(),
          path = module.adapter_config().endpoint_path,
          expected = implied[path],
          not is_nil(expected) do
        assert Registry.request_format(module) == expected,
               "#{inspect(module)} serves #{path} but declares " <>
                 "#{inspect(Registry.request_format(module))}"
      end
    end

    test "every registered adapter either forwards headers or says why not" do
      for module <- Registry.registered_modules() do
        case Map.fetch(@cannot_forward, module) do
          {:ok, reason} ->
            assert is_binary(reason) and reason != ""

          :error ->
            # function_exported?/3 answers "loaded AND exported", and in the
            # test env modules load lazily — without this the sweep failed or
            # passed depending on whether an earlier test happened to touch the
            # adapter, which is the one thing a guard test must not do.
            Code.ensure_loaded!(module)

            assert function_exported?(module, :request_headers, 2),
                   "#{inspect(module)} makes upstream requests but exposes no request_headers/2 " <>
                     "— it cannot honour the request-fidelity policy"
        end
      end
    end
  end

  describe "every adapter records the bytes it sends" do
    # The same gap in the other direction: `outbound_body` was populated by one
    # adapter out of twelve, so the Trace could not show an operator what any
    # other provider actually received. `Adapter.record_outbound_body/1` both
    # records it and returns the payload size every adapter already needed, so
    # complying is the path of least resistance rather than an extra step.
    #
    # Unlike the header sweep there is no public function to call — the record
    # happens inside a request builder — so this reads the source. A blunt
    # instrument, but it is the difference between a new adapter failing loudly
    # and silently dropping off the Trace.
    #
    # The rule is "whoever makes the request records the bytes", so adapters
    # that delegate their transport (Groq, Mistral, xAI, DeepSeek, Codex) are
    # exempt by construction rather than by a hand-kept list that would go
    # stale: the module they delegate to is swept on its own.
    test "every adapter that makes its own request records what it sent" do
      for module <- Registry.registered_modules() do
        Code.ensure_loaded!(module)
        source = module.module_info(:compile)[:source] |> to_string() |> File.read!()

        if source =~ ~r/Req\.(post|request|get)\(/ do
          assert source =~ "record_outbound_body",
                 "#{inspect(module)} makes its own HTTP request but never calls " <>
                   "Adapter.record_outbound_body/1, so the Trace cannot show the bytes it " <>
                   "sent. Call it where the payload size is computed — it returns that size."
        end
      end
    end
  end
end
