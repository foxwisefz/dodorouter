defmodule DodoRouter.Proxy.Fidelity do
  @moduledoc """
  Records everything the proxy removes or rewrites on its way to a provider,
  so an operator can answer "what did the proxy change about my request?".

  The 2026-08-08 request-fidelity policy has two halves. The first — forward
  client headers by default, strip only for three stated reasons — is
  enforceable in code. The second is not: *"the provider will break"* is not
  knowable in advance for every provider × header pair, so breakage gets
  discovered in production and the strip list grows by accretion. Unless every
  removal is recorded, that list decays into folklore: someone adds an entry
  after an outage and a year later nobody remembers which provider, or why.

  ## Three loss channels, one surface

    * `request_header` — a client header the policy did not forward
    * `request_body`   — a field dropped by one of the whitelist conversions
    * `response_body`  — a native provider field not passed back to the client

  All three land in `request_logs.fidelity_changes` as a flat list of maps, the
  way `truncation_flags` already records what logging itself altered.

  ## Why a process dictionary

  Header policy lives in exactly one function (`Adapter.build_forwarded_headers/2`),
  and body policy in exactly one more (`Adapter.sanitize_request/1`). Recording
  at those two points means every adapter is covered automatically, including
  ones written later — whereas asking each adapter to thread a record back
  through its return value is the pattern that gave us `outbound_headers`
  populated by two adapters out of twelve.

  Adapters run inline in the caller's process (`Req` streams into the caller
  too), so `FallbackChain` can reset the buffer before a step and harvest it
  after. Anything that ever moves an adapter call into its own task must move
  the harvest with it.
  """

  @key :__dodo_fidelity__

  @empty %{changes: [], outbound_headers: nil}

  @reasons %{
    replaced_by_proxy: "the proxy authenticates with its own credentials",
    transport:
      "describes a hop or a body we rewrite; forwarding it breaks the request or the stream",
    account_scoped: "names the client's account on a provider we authenticate to with our key",
    not_client_sent: "added by our edge, or not the client's to send",
    proxy_value_wins: "collides with a header the proxy must set itself",
    not_in_provider_allowlist: "not a field the upstream Chat Completions API accepts",
    unsupported_by_format_conversion: "the format conversion has no translation for it yet"
  }

  @doc """
  Clears the buffer. Call before dispatching a routing step so one step's
  record cannot be attributed to the next.
  """
  def reset do
    Process.delete(@key)
    :ok
  end

  @doc """
  Returns the buffer and clears it: `%{changes: [...], outbound_headers: [...]}`.

  `outbound_headers` is what actually went upstream — the client's surviving
  headers plus the proxy's own. It comes free from recording at the policy
  point, and covers the adapters that never populated it themselves.
  """
  def take do
    record = Process.get(@key, @empty)
    Process.delete(@key)
    record
  end

  @doc """
  Records the outcome of the header policy for one upstream request.

  `dropped` is a list of `{header_name, reason_atom}`; `outbound` is the full
  header list being sent.
  """
  def record_headers(dropped, outbound) do
    changes = Enum.map(dropped, &change("request_header", elem(&1, 0), "dropped", elem(&1, 1)))

    update(fn record ->
      %{record | changes: record.changes ++ changes, outbound_headers: outbound}
    end)
  end

  @doc """
  Records a header the proxy sent upstream with a value other than the
  client's. Distinct from a drop: `anthropic-beta` is *merged*, and reporting
  that as "dropped, collides with a proxy header" would be a lie that sends the
  next person debugging a cache miss in the wrong direction.
  """
  def record_header_rewrite(name, detail) do
    record(change("request_header", name, "rewritten", :proxy_value_wins, detail))
  end

  @doc """
  Records request-body fields removed by a whitelist.

  `reason` is `:not_in_provider_allowlist` for the per-step egress allowlist or
  `:unsupported_by_format_conversion` for an ingress converter that has no
  translation for the field yet.
  """
  def record_dropped_body_fields(fields, reason, detail \\ nil)

  def record_dropped_body_fields([], _reason, _detail), do: :ok

  def record_dropped_body_fields(fields, reason, detail) do
    fields
    |> Enum.map(&change("request_body", &1, "dropped", reason, detail))
    |> Enum.each(&record/1)
  end

  @doc """
  Records native response fields the proxy did not pass back to the client.
  """
  def record_dropped_response_fields(fields, detail \\ nil)

  def record_dropped_response_fields([], _detail), do: :ok

  def record_dropped_response_fields(fields, detail) do
    fields
    |> Enum.map(
      &change("response_body", &1, "dropped", :unsupported_by_format_conversion, detail)
    )
    |> Enum.each(&record/1)
  end

  @doc """
  Tags a step's changes with the provider and position that produced them.

  Header and body policy re-run per step, so the same client request can lose
  different things at step 1 and step 5 — which is exactly the case an operator
  is looking at when a fallback behaves differently from the original.
  """
  def attribute(changes, provider, position) when is_list(changes) do
    Enum.map(changes, fn change ->
      change
      |> Map.put("provider", provider)
      |> Map.put("step", position)
    end)
  end

  @doc """
  The human-readable justification behind a recorded reason, for the log UI.
  """
  def explain(reason) when is_binary(reason) do
    Map.get(@reasons, safe_atom(reason), reason)
  end

  def explain(_), do: nil

  defp safe_atom(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> nil
  end

  defp change(channel, name, action, reason, detail \\ nil) do
    %{
      "channel" => channel,
      "name" => to_string(name),
      "action" => action,
      "reason" => to_string(reason)
    }
    |> maybe_put("detail", detail)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp record(change) do
    update(fn record -> %{record | changes: record.changes ++ [change]} end)
  end

  defp update(fun) do
    Process.put(@key, fun.(Process.get(@key, @empty)))
    :ok
  end
end
