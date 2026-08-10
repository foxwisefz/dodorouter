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
    test "every registered adapter either forwards headers or says why not" do
      for module <- Registry.registered_modules() do
        case Map.fetch(@cannot_forward, module) do
          {:ok, reason} ->
            assert is_binary(reason) and reason != ""

          :error ->
            assert function_exported?(module, :request_headers, 2),
                   "#{inspect(module)} makes upstream requests but exposes no request_headers/2 " <>
                     "— it cannot honour the request-fidelity policy"
        end
      end
    end
  end
end
