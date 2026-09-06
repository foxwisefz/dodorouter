defmodule DodoRouter.Logs.CacheDiagnostics do
  @moduledoc """
  Privacy-safe evidence about the final outbound request, independent of body
  retention. Hashes are router-scoped HMACs, never unkeyed prompt hashes.
  A structural difference is an observation, not proof of provider causality.
  Message indices are one-based; appending messages is normal prefix growth.
  """

  @components ~w(model tools system messages cache_control parameters)
  @body_fields ~w(model tools system systemInstruction instructions messages input contents)
  @roles ~w(system developer user assistant tool function model)
  @max_items 4096
  @control_keys ~w(cache_control prompt_cache_breakpoint)
  @cache_headers ~w(anthropic-beta anthropic-version openai-beta chatgpt-account-id session_id conversation_id x-session-id)

  def fingerprint(body, router_id, opts \\ [])

  def fingerprint(body, router_id, opts) when is_map(body) do
    secret = opts[:secret] || DodoRouterWeb.Endpoint.config(:secret_key_base)
    key = :crypto.mac(:hmac, :sha256, secret, "dodo-cache-v1:" <> router_id)
    messages = List.wrap(body["messages"] || body["input"] || body["contents"])
    tools = List.wrap(body["tools"])

    system =
      List.wrap(
        body["system"] || body["systemInstruction"] || body["instructions"] ||
          Enum.filter(messages, &(is_map(&1) and &1["role"] in ["system", "developer"]))
      )

    if length(messages) + length(tools) + length(system) <= @max_items do
      controls = cache_controls(body)

      %{
        "version" => 1,
        "key_id" => hash(key, "key-id"),
        "routing" => hash(key, opts[:routing]),
        "routing_context" => routing_context(key, opts[:routing]),
        "served_model" => opts[:served_model],
        "cache_key_hash" => optional_hash(key, body["prompt_cache_key"]),
        "cache_settings_hash" =>
          hash(key, Map.take(body, ~w(prompt_cache_options prompt_cache_retention))),
        "requested_retention" => safe_retention(body),
        "cache_headers" => header_hashes(key, opts[:outbound_headers]),
        "started_at_ms" => opts[:started_at_ms],
        "finished_at_ms" => opts[:finished_at_ms],
        "other_in_flight_router_requests" => opts[:other_in_flight_router_requests],
        "model" => hash(key, body["model"]),
        "tools" => Enum.map(tools, &entry(key, &1)),
        "system" => Enum.map(system, &entry(key, &1)),
        "messages" => Enum.map(messages, &entry(key, &1)),
        "cache_control" => hash(key, controls),
        "requested_ttl_seconds" => uniform_ttl(controls),
        "parameters" =>
          hash(
            key,
            Map.drop(
              body,
              @body_fields ++
                @control_keys ++ ~w(prompt_cache_key prompt_cache_options prompt_cache_retention)
            )
          ),
        "provider_shard" => nil,
        "provider_expiry" => nil,
        "token_counts" => "unavailable"
      }
    end
  end

  def fingerprint(_, _, _), do: nil

  defp entry(key, value) do
    content = strip_controls(value)
    role = if is_map(value) and value["role"] in @roles, do: value["role"]
    %{"hash" => hash(key, content), "bytes" => byte_size(Jason.encode!(content)), "role" => role}
  end

  defp optional_hash(_key, nil), do: nil
  defp optional_hash(_key, ""), do: nil
  defp optional_hash(key, value), do: hash(key, value)

  defp hash(key, value) do
    :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(canonical(value)))
    |> Base.encode16(case: :lower)
  end

  # Tagged objects cannot collide with arrays of key/value pairs; array order
  # and scalar types survive, while JSON object insertion order does not.
  defp canonical(value) when is_map(value),
    do:
      {:object,
       value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, canonical(v)} end)}

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp strip_controls(value) when is_map(value),
    do:
      Map.new(Map.drop(value, @control_keys), fn
        {k, v} when k in ["content", "parts"] and is_list(v) ->
          {k, Enum.map(v, &strip_controls/1)}

        pair ->
          pair
      end)

  defp strip_controls(value) when is_list(value), do: Enum.map(value, &strip_controls/1)
  defp strip_controls(value), do: value

  # Paths and raw control values are only held transiently and hashed. They
  # never become diagnostic text, including arbitrary nested object keys.
  defp cache_controls(body) do
    own_controls(body, []) ++
      Enum.flat_map(
        ~w(tools system systemInstruction instructions messages input contents),
        fn field ->
          body[field]
          |> List.wrap()
          |> Enum.with_index()
          |> Enum.flat_map(fn {item, i} -> cache_controls(item, [field, i]) end)
        end
      )
  end

  defp cache_controls(value, path) when is_map(value) do
    own_controls(value, path) ++
      Enum.flat_map(["content", "parts"], fn field ->
        case value[field] do
          children when is_list(children) -> cache_controls(children, path ++ [field])
          _ -> []
        end
      end)
  end

  defp cache_controls(value, path) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, i} -> cache_controls(child, path ++ [i]) end)

  defp cache_controls(_, _), do: []

  defp own_controls(value, path) do
    Enum.flat_map(@control_keys, fn field ->
      if Map.has_key?(value, field), do: [{path ++ [field], value[field]}], else: []
    end)
  end

  defp routing_context(key, {provider, provider_key_id, endpoint}),
    do: %{
      "provider" => provider,
      "provider_key_id" => provider_key_id,
      "endpoint_hash" => optional_hash(key, endpoint)
    }

  defp routing_context(_, _), do: %{}

  defp header_hashes(_key, nil), do: nil

  defp header_hashes(key, headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)
    |> Enum.filter(fn {name, _} -> name in @cache_headers end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, values} -> {name, hash(key, values)} end)
  end

  defp safe_retention(body) do
    options = body["prompt_cache_options"]
    ttl = if is_map(options), do: options["ttl"]
    retention = body["prompt_cache_retention"]

    cond do
      ttl in ["30m"] -> ttl
      retention in ["in_memory", "24h"] -> retention
      true -> nil
    end
  end

  defp public_evidence(nil), do: nil

  defp public_evidence(fp) do
    Map.take(
      fp,
      ~w(routing_context served_model cache_key_hash requested_retention requested_ttl_seconds started_at_ms finished_at_ms other_in_flight_router_requests provider_shard provider_expiry)
    )
  end

  # No provider default is invented; mixed TTLs do not imply one expiry.
  defp uniform_ttl(controls) do
    case Enum.uniq(
           Enum.map(controls, fn
             {_, %{"ttl" => "5m"}} -> 300
             {_, %{"ttl" => "1h"}} -> 3600
             _ -> nil
           end)
         ) do
      [ttl] -> ttl
      _ -> nil
    end
  end

  def diagnose(current, previous) do
    read = current.cache_read_tokens

    observation =
      cond do
        is_nil(read) -> "unreported"
        read == 0 -> "zero_read"
        true -> "cache_read"
      end

    base = %{
      "observation" => observation,
      "cache_read_tokens" => read,
      "cache_write_tokens" => current.cache_write_tokens,
      "previous_cache_read_tokens" => if(previous, do: previous.cache_read_tokens),
      "previous_cache_write_tokens" => if(previous, do: previous.cache_write_tokens),
      "previous_log_id" => if(previous, do: previous.id),
      "current" => public_evidence(current.cache_fingerprint),
      "previous" => public_evidence(if(previous, do: previous.cache_fingerprint)),
      "cause" => "unknown",
      "confidence" => "unknown",
      "first_change" => nil
    }

    a = if previous, do: previous.cache_fingerprint
    b = current.cache_fingerprint

    cond do
      observation == "unreported" ->
        explain(base, "Provider did not report cache-read usage.")

      not is_map(a) or not is_map(b) ->
        explain(base, "No comparable earlier fingerprint is available.")

      a["version"] != b["version"] or a["key_id"] != b["key_id"] ->
        explain(base, "Fingerprint version or signing key changed; comparison unavailable.")

      a["routing"] != b["routing"] or a["model"] != b["model"] or
          a["served_model"] != b["served_model"] ->
        base
        |> Map.put("changes", context_changes(a, b))
        |> explain(
          "Model, provider, endpoint, or provider key changed; cache reuse is not assumed."
        )

      true ->
        compare(base, a, b)
    end
  end

  defp compare(base, a, b) do
    change = Enum.find_value(@components, &changed_component(&1, a[&1], b[&1]))
    base = Map.put(base, "first_change", change)

    base =
      base
      |> Map.put("changes", context_changes(a, b))
      |> Map.put("matched_messages", matched_messages(a["messages"], b["messages"]))
      |> Map.put("previous_message_count", length(a["messages"]))

    age = difference(b["started_at_ms"], a["finished_at_ms"])
    overlap = is_number(age) and age < 0
    base = Map.merge(base, %{"gap_ms" => age, "overlapping_previous_request" => overlap})

    cond do
      base["changes"]["cache_key"] or base["changes"]["cache_settings"] or
          base["changes"]["cache_headers"] ->
        explain(
          base,
          "Cache routing key, requested retention, or tracked provider headers changed; cache reuse is not assumed."
        )

      change && change["component"] == "parameters" ->
        explain(base, "Provider parameters changed; their effect on caching is unknown.")

      change ->
        base
        |> verdict("prefix_changed", "observed")
        |> explain(
          change_message(change) <>
            " This may explain lost cache reuse; provider causality is unconfirmed."
        )

      base["observation"] == "cache_read" ->
        explain(base, "Shared request prefix unchanged; provider reported cache reads.")

      overlap and cached_before?(base) ->
        base
        |> verdict("parallel_race", "possible")
        |> explain(
          "Shared prefix unchanged; the previous request was still in flight when this one started. A cache-write race is possible."
        )

      cached_before?(base) and is_integer(a["requested_ttl_seconds"]) and is_number(age) and
          age > a["requested_ttl_seconds"] * 1000 ->
        base
        |> verdict("cache_expired", "likely")
        |> explain(
          "Shared prefix unchanged; time since the previous request exceeds its requested TTL. Expiry is likely, not confirmed."
        )

      true ->
        base
        |> verdict("provider_no_hit", "unknown")
        |> explain(
          "Shared prefix unchanged, but provider reported zero cache reads. Cache eligibility, expiry, shard, and provider-side causes are unknown."
        )
    end
  end

  defp context_changes(a, b) do
    ar = a["routing_context"] || %{}
    br = b["routing_context"] || %{}

    %{
      "provider" => ar["provider"] != br["provider"],
      "provider_key" => ar["provider_key_id"] != br["provider_key_id"],
      "endpoint" => ar["endpoint_hash"] != br["endpoint_hash"],
      "model" => a["model"] != b["model"] or a["served_model"] != b["served_model"],
      "cache_key" => a["cache_key_hash"] != b["cache_key_hash"],
      "cache_settings" => a["cache_settings_hash"] != b["cache_settings_hash"],
      "cache_headers" => a["cache_headers"] != b["cache_headers"],
      "tools" => a["tools"] != b["tools"],
      "system" => a["system"] != b["system"],
      "cache_control" => a["cache_control"] != b["cache_control"],
      "parameters" => a["parameters"] != b["parameters"]
    }
  end

  defp matched_messages(before, after_) do
    Enum.zip(before, after_)
    |> Enum.take_while(fn {a, b} -> a["hash"] == b["hash"] end)
    |> length()
  end

  defp changed_component("messages" = component, before, after_) do
    index =
      before
      |> Enum.with_index()
      |> Enum.find_value(fn {item, i} ->
        if item["hash"] != get_in(Enum.at(after_, i) || %{}, ["hash"]), do: i + 1
      end)

    if index do
      item = Enum.at(after_, index - 1) || Enum.at(before, index - 1)
      %{"component" => component, "index" => index, "role" => item["role"]}
    end
  end

  defp changed_component(component, before, after_) when component in ["tools", "system"] do
    if before != after_ do
      index = Enum.zip(before, after_) |> Enum.find_index(fn {a, b} -> a != b end)

      %{
        "component" => component,
        "index" => if(index, do: index + 1, else: min(length(before), length(after_)) + 1)
      }
    end
  end

  defp changed_component(_, same, same), do: nil
  defp changed_component(component, _, _), do: %{"component" => component}

  defp change_message(%{"component" => "messages", "index" => index, "role" => role}),
    do: "#{String.capitalize(role || "conversation")} message #{index} changed or was removed."

  defp change_message(%{"component" => "tools", "index" => index}),
    do: "Tools changed at item #{index} (including order)."

  defp change_message(%{"component" => "system", "index" => index}),
    do: "System prompt changed at item #{index}."

  defp change_message(%{"component" => "cache_control"}),
    do: "Cache breakpoint placement or settings changed."

  defp change_message(_), do: "Request structure changed."

  defp cached_before?(base),
    do:
      (base["previous_cache_read_tokens"] || 0) > 0 or
        (base["previous_cache_write_tokens"] || 0) > 0

  defp difference(a, b) when is_integer(a) and is_integer(b), do: a - b
  defp difference(_, _), do: nil
  defp explain(base, message), do: Map.put(base, "message", message <> comparison_summary(base))

  defp comparison_summary(%{"matched_messages" => count, "changes" => changes} = base) do
    messages = " #{count} of #{base["previous_message_count"]} previous messages match."

    tools =
      if not changes["tools"] and not changes["system"],
        do: " Tools and system prompt unchanged.",
        else: ""

    key =
      if get_in(base, ["current", "routing_context", "provider_key_id"]) &&
           not changes["provider_key"], do: " Same provider key.", else: ""

    gap =
      case base["gap_ms"] do
        ms when is_integer(ms) and ms >= 0 ->
          " Previous request completed #{Float.round(ms / 1000, 1)}s before this attempt."

        _ ->
          ""
      end

    messages <> tools <> key <> gap
  end

  defp comparison_summary(_), do: ""

  defp verdict(base, cause, confidence),
    do: Map.merge(base, %{"cause" => cause, "confidence" => confidence})
end
