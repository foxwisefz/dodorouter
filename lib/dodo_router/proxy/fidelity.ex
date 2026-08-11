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

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Redact

  @key :__dodo_fidelity__

  # We deliberately do not store the client's original request body
  # (dodo_router-5ha), which makes this diff the *only* record of what was
  # asked for — so a row that names a field without showing it cannot answer
  # the one question the panel exists for. Recording the value costs the
  # dropped fields rather than the whole body, but a dropped field can still be
  # one of the megabyte-sized ones a coding agent sends, so it is capped. The
  # cut is announced: silently halving a value is a second loss on top of the
  # one being reported.
  @value_limit 2_000

  @empty %{changes: [], outbound_headers: nil}

  @reasons %{
    replaced_by_proxy: "the proxy authenticates with its own credentials",
    transport:
      "describes a hop or a body we rewrite; forwarding it breaks the request or the stream",
    account_scoped: "names the client's account on a provider we authenticate to with our key",
    not_client_sent: "not the client's to hand to a third party",
    edge_added: "our own edge added it; the client never sent it",
    proxy_value_wins: "collides with a header the proxy must set itself",
    not_in_provider_allowlist: "not a field the upstream Chat Completions API accepts",
    unsupported_by_format_conversion: "the format conversion has no translation for it yet"
  }

  # Three reasons say nothing about the request they are attached to, because
  # they are true of every request ever made: `host`/`content-length`/
  # `accept-encoding` always come off, `x-forwarded-*`/`via` were never the
  # caller's headers at all (our edge put them there), and `authorization` is
  # replaced with our own credential — which is the definition of being a
  # proxy, not news about this call. A dozen such rows buried the two or three
  # drops that were genuinely about what this client asked for, which is the
  # only question the panel exists to answer.
  #
  # The bar: would an operator debugging *this* request learn anything? A
  # collision on `anthropic-version` stays reported — the client picked a value
  # and we sent a different one. Nobody is surprised we hold the API key.
  @silent_reasons ~w(transport edge_added replaced_by_proxy)

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
    changes =
      dropped
      |> Enum.reject(fn {_name, reason} -> to_string(reason) in @silent_reasons end)
      |> Enum.map(&change("request_header", elem(&1, 0), "dropped", elem(&1, 1)))

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

  `fields` is a map of `name => value` — the value is what the client asked
  for, and is recorded alongside the name (redacted and length-capped) so the
  row stands on its own. A bare list of names is still accepted for callers
  that genuinely have no value to hand over; those rows carry no `"value"` key
  rather than a fabricated one.

  `reason` is `:not_in_provider_allowlist` for the per-step egress allowlist or
  `:unsupported_by_format_conversion` for an ingress converter that has no
  translation for the field yet.
  """
  def record_dropped_body_fields(fields, reason, detail \\ nil)

  def record_dropped_body_fields(fields, reason, detail) do
    record_dropped("request_body", fields, reason, detail)
  end

  @doc """
  Records native response fields the proxy did not pass back to the client.

  Takes the same `name => value` map as `record_dropped_body_fields/3`, for the
  same reason: the client never sees these, so the log is the only place they
  survive at all.
  """
  def record_dropped_response_fields(fields, detail \\ nil)

  def record_dropped_response_fields(fields, detail) do
    record_dropped("response_body", fields, :unsupported_by_format_conversion, detail)
  end

  @doc """
  Builds the same rows `record_dropped_body_fields/3` records, without touching
  the buffer.

  The ingress format converters run once, before any routing step exists, so
  their losses are attached to the log directly by `Proxy` rather than harvested
  per step — but they are the same rows, and must be redacted and capped the
  same way.
  """
  def dropped_body_changes(fields, reason, detail \\ nil) do
    build_dropped("request_body", fields, reason, detail)
  end

  defp record_dropped(channel, fields, reason, detail) do
    channel
    |> build_dropped(fields, reason, detail)
    |> Enum.each(&record/1)
  end

  defp build_dropped(channel, fields, reason, detail) do
    fields
    |> normalize_fields()
    |> Enum.map(fn {name, value} ->
      channel
      |> change(name, "dropped", reason, detail)
      |> maybe_put("value", preview(value))
    end)
  end

  # Sorted so a request that drops the same set of fields twice (once per
  # fallback step) reads identically on both steps.
  defp normalize_fields(fields) when is_map(fields) do
    fields |> Enum.map(fn {name, value} -> {name, {:value, value}} end) |> Enum.sort()
  end

  defp normalize_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      {name, value} -> {name, {:value, value}}
      name -> {name, :no_value}
    end)
  end

  defp preview(:no_value), do: nil

  defp preview({:value, value}) do
    value
    |> encode_value()
    |> Redact.redact_secrets()
    |> truncate()
  end

  defp encode_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _not_encodable -> inspect(value)
    end
  end

  defp truncate(value) do
    case String.length(value) do
      length when length > @value_limit ->
        String.slice(value, 0, @value_limit) <>
          "… [truncated, #{length - @value_limit} more characters]"

      _within_limit ->
        value
    end
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
  Whether a persisted change should stay out of the log page's list.

  Read-time filtering as well as record-time is what makes the rule
  retroactive. Rows written before `:edge_added` existed carry
  `not_client_sent` for `x-forwarded-for`, so the stored reason cannot tell an
  edge header apart from a cookie — re-classifying the header name under
  today's policy can.
  """
  def hidden?(%{} = change) do
    name = change["name"]

    to_string(change["reason"]) in @silent_reasons or
      (change["channel"] == "request_header" and is_binary(name) and
         to_string(Adapter.strip_reason(name)) in @silent_reasons)
  end

  def hidden?(_change), do: false

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
