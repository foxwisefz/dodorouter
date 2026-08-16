defmodule DodoRouter.Replays do
  @moduledoc """
  Re-runs a stored request log against a different provider/model.

  The replay is dispatched through the normal proxy pipeline with a single
  synthetic routing step, logged synchronously, and linked back to the
  original log via `replayed_from_id`.
  """

  alias DodoRouter.Accounts.User
  alias DodoRouter.Logs
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Models
  alias DodoRouter.Providers
  alias DodoRouter.Proxy
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouter.Repo
  alias DodoRouter.Routers.RoutingStep

  # Client-directed fields that must not be re-sent on a server-initiated
  # replay. "model" is re-set to the target below.
  @strip_fields ~w(stream stream_options user metadata store _truncation_flags)

  @doc """
  Re-runs `source`'s stored request against `target`.

  `target` is `%{provider_key_id: id, model: model}` — the provider key
  must belong to `user` (ownership of `source` is the caller's concern;
  load it via `Logs.get_log/2`).

  Returns `{:ok, replay_log}` whenever a replay was dispatched and
  persisted — including provider failures, which are captured in the log's
  `status`/`attempted_steps`. Returns `{:error, reason}` only when the
  replay could not be dispatched at all (`:truncated`,
  `:invalid_request_body`, `:missing_messages`, `:invalid_model`,
  `:provider_key_not_found`, `:log_not_persisted`).
  """
  def replay(
        %User{} = user,
        %RequestLog{} = source,
        %{provider_key_id: key_id, model: model} = target
      ) do
    # Replays always anchor to the chain's root: every candidate re-runs the
    # same original request and lands as a sibling in one comparison hub,
    # rather than growing replay-of-replay chains.
    root = source |> Logs.root_of() |> Repo.preload(:router)
    effort = normalize_effort(target[:reasoning_effort])
    message_index = target[:message_index]
    system_prompt = target[:system_prompt]
    message_patches = target[:message_patches]

    with :ok <- validate_effort(effort),
         {:ok, request} <-
           prepare_request(root, model, effort, message_index,
             system_prompt: system_prompt,
             message_patches: message_patches
           ),
         {:ok, step} <- build_step(user, root.router_id, key_id, model, effort) do
      request_id = Ecto.UUID.generate()

      opts = [
        steps: [step],
        log_mode: :sync,
        replayed_from_id: root.id,
        replay_from_index: message_index,
        request_id: request_id,
        client_headers: replayable_headers(root),
        traffic_type: target[:traffic_type] || "proxy"
      ]

      case Proxy.dispatch(root.router, request, opts) do
        {:ok, _response, %{log: %RequestLog{} = log}} -> {:ok, log}
        {:ok, _response, _meta} -> fetch_persisted(request_id)
        {:error, :all_providers_failed, _attempts} -> fetch_persisted(request_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A replay stands in for the traffic it replays, so it has to reach the
  # provider carrying what that traffic carried. Headers are the half everyone
  # forgets: without the client's `anthropic-beta` the replay runs on a
  # different cache TTL and potentially different model behaviour, which makes
  # the score delta a downgrade decision rests on a measurement of a request
  # nobody ever sent.
  #
  # Two things do not travel. Credentials were redacted on the way into the
  # log, so the stored value is a marker rather than a secret — and the replay
  # authenticates with the router's own key anyway, so sending the marker
  # upstream would be garbage, not fidelity. Everything else goes to
  # `Adapter.build_forwarded_headers/2`, the same policy live traffic passes
  # through, which strips what a provider must not see.
  @redaction_marker "[REDACTED]"

  defp replayable_headers(%RequestLog{request_headers: stored}) do
    case decode_headers(stored) do
      nil -> []
      headers -> Enum.reject(headers, fn {_k, v} -> String.contains?(v, @redaction_marker) end)
    end
  end

  defp decode_headers(nil), do: nil

  defp decode_headers(stored) when is_binary(stored) do
    case Jason.decode(stored) do
      {:ok, headers} when is_list(headers) ->
        Enum.flat_map(headers, fn
          [k, v] when is_binary(k) and is_binary(v) -> [{k, v}]
          _ -> []
        end)

      _ ->
        nil
    end
  end

  @doc """
  Decodes and sanitizes the stored request body for re-dispatch.

  When an explicit `reasoning_effort` is chosen for the target, the body's
  own `reasoning_effort`/`thinking` params are stripped — the step-level
  effort is only an opt-in default at the adapter layer, so a leftover body
  value would silently win over the user's choice.
  """
  def prepare_request(
        source,
        target_model,
        reasoning_effort \\ nil,
        message_index \\ nil,
        overrides \\ []
      )

  def prepare_request(
        %RequestLog{} = source,
        target_model,
        reasoning_effort,
        message_index,
        overrides
      ) do
    with :ok <- validate_model(target_model),
         {:ok, decoded} <- decode_body(source.request_body),
         :ok <- ensure_messages(decoded),
         {:ok, decoded} <- truncate_at(decoded, message_index),
         :ok <- ensure_not_truncated(decoded),
         # Patches apply before the system-prompt override: their indexes
         # refer to the messages array as served, and apply_system_prompt
         # may prepend a message, which would shift every index by one.
         {:ok, decoded} <- apply_message_patches(decoded, overrides[:message_patches]) do
      request =
        decoded
        |> Map.drop(@strip_fields)
        |> drop_reasoning_params(reasoning_effort, decoded["model"], target_model)
        |> apply_system_prompt(overrides[:system_prompt])
        |> Map.put("model", target_model)

      {:ok, request}
    end
  end

  # Replaces the content of the message at each patched index — the
  # mechanism behind context-transform experiments ("does compressing tool
  # output preserve reasoning?"): same frozen history, one bit flipped, no
  # world drift. The transform is computed by the caller; the router never
  # executes client code. An index with no message behind it is an error,
  # not a skip — a benchmark that silently measured the unpatched request
  # would be confidently wrong.
  defp apply_message_patches(decoded, nil), do: {:ok, decoded}
  defp apply_message_patches(decoded, []), do: {:ok, decoded}

  defp apply_message_patches(%{"messages" => messages} = decoded, patches)
       when is_list(patches) do
    count = length(messages)

    if Enum.all?(patches, &valid_patch?(&1, count)) do
      messages =
        Enum.reduce(patches, messages, fn patch, acc ->
          index = patch["index"] || patch[:index]
          content = if Map.has_key?(patch, "content"), do: patch["content"], else: patch[:content]
          List.update_at(acc, index, &Map.put(&1, "content", content))
        end)

      {:ok, Map.put(decoded, "messages", messages)}
    else
      {:error, :invalid_message_patch}
    end
  end

  defp apply_message_patches(_decoded, _patches), do: {:error, :invalid_message_patch}

  defp valid_patch?(patch, count) when is_map(patch) do
    index = patch["index"] || patch[:index]
    content = if Map.has_key?(patch, "content"), do: patch["content"], else: patch[:content]

    is_integer(index) and index >= 0 and index < count and
      (is_binary(content) or is_list(content))
  end

  defp valid_patch?(_patch, _count), do: false

  @doc """
  Applies message patches to a stored request body — the judge-side twin of
  `patch_system_prompt/2`, so what the judge reads is what the run sent.
  Returns the body unchanged when there is nothing to patch or the body
  cannot be decoded; an invalid patch already failed the run before any
  judge saw it.
  """
  def patch_messages(request_body, patches)
      when is_binary(request_body) and is_list(patches) and patches != [] do
    case Jason.decode(request_body) do
      {:ok, %{"messages" => _} = decoded} ->
        case apply_message_patches(decoded, patches) do
          {:ok, patched} -> Jason.encode!(patched)
          {:error, _} -> request_body
        end

      _ ->
        request_body
    end
  end

  def patch_messages(request_body, _patches), do: request_body

  # Replaces the system message's content — or prepends one when the served
  # request had none. The replay-a-real-log anchor stays: everything else
  # about the request is exactly what was served, only the hypothesis under
  # test changes (dodo_router-kk1).
  defp apply_system_prompt(request, nil), do: request

  defp apply_system_prompt(%{"messages" => messages} = request, prompt)
       when is_binary(prompt) do
    {messages, replaced?} =
      Enum.map_reduce(messages, false, fn
        %{"role" => "system"} = msg, false -> {Map.put(msg, "content", prompt), true}
        msg, replaced? -> {msg, replaced?}
      end)

    messages =
      if replaced?,
        do: messages,
        else: [%{"role" => "system", "content" => prompt} | messages]

    Map.put(request, "messages", messages)
  end

  @doc """
  The same patch, applied to a stored request-body JSON string — what the
  judge scores against must be the request the run actually sent.
  """
  def patch_system_prompt(request_body, nil), do: request_body

  def patch_system_prompt(request_body, prompt) when is_binary(request_body) do
    case Jason.decode(request_body) do
      {:ok, %{"messages" => _} = decoded} ->
        Jason.encode!(apply_system_prompt(decoded, prompt))

      _ ->
        request_body
    end
  end

  def patch_system_prompt(request_body, _prompt), do: request_body

  # Cut the history at the chosen user message (inclusive) so the replay
  # asks "what would this model have answered at that exchange". Runs
  # before the storage-truncation check so markers after the cut don't
  # block a partial replay.
  defp truncate_at(decoded, nil), do: {:ok, decoded}

  defp truncate_at(%{"messages" => messages} = decoded, index) when is_integer(index) do
    case Enum.at(messages, index) do
      %{"role" => "user"} when index >= 0 ->
        {:ok, Map.put(decoded, "messages", Enum.take(messages, index + 1))}

      _other ->
        {:error, :invalid_message_index}
    end
  end

  defp truncate_at(_decoded, _index), do: {:error, :invalid_message_index}

  @doc """
  Returns the reason the given log can't be replayed, or nil when it can.

  With a `message_index`, checks replayability of just the history up to
  that message — storage truncation after the cut doesn't block a partial
  replay.
  """
  def replay_blocker(%RequestLog{} = source, message_index \\ nil) do
    case prepare_request(source, "replay-probe", nil, message_index) do
      {:ok, _request} -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  The `%{provider_key_id, model}` that actually served a log — the incumbent
  an evaluation needs as its baseline — or `nil` when the serving key is
  unknown (legacy rows, or steps that predate provider keys).
  """
  def incumbent_target(%RequestLog{} = log) do
    (log.attempted_steps || [])
    |> Enum.find(fn step -> step["status"] == "success" && step["provider_key_id"] end)
    |> case do
      %{"provider_key_id" => key_id} = step ->
        %{provider_key_id: key_id, model: log.final_model || step["model"]}

      _ ->
        nil
    end
  end

  @doc """
  Builds the synthetic routing step for a replay target.

  Sampling params (`temperature`, `max_tokens`, `thinking_enabled`) are left
  nil so the replayed request body's own values pass through untouched.
  `reasoning_effort` is set only when the user explicitly chose one.
  """
  def build_step(%User{} = user, router_id, provider_key_id, model, reasoning_effort \\ nil) do
    case Providers.get_provider_key(user, provider_key_id) do
      nil ->
        {:error, :provider_key_not_found}

      provider_key ->
        {:ok,
         %RoutingStep{
           id: Ecto.UUID.generate(),
           router_id: router_id,
           position: 0,
           provider: Registry.adapter_provider(provider_key.provider_slug),
           model: model,
           plan_type: plan_type_for(provider_key),
           reasoning_effort: reasoning_effort,
           provider_key: provider_key,
           provider_key_id: provider_key.id
         }}
    end
  end

  @doc """
  Replay targets available to the user: one entry per configured provider
  key, with the models offered for it (pricing catalog first, adapter
  registry as fallback for models the catalog doesn't know).
  """
  def list_targets(%User{} = user) do
    user
    |> Providers.list_provider_keys()
    |> Enum.filter(&offerable_key?/1)
    |> Enum.map(fn key ->
      provider = Registry.adapter_provider(key.provider_slug)
      info = Registry.display_info(key.provider_slug)

      %{
        provider_key: key,
        provider: provider,
        display_name: info.name,
        models: models_for(key, provider)
      }
    end)
  end

  @metrics [
    {:latency_ms, "Latency", :lower},
    {:ttfb_ms, "TTFB", :lower},
    {:prompt_tokens, "Prompt tokens", :lower},
    {:completion_tokens, "Completion tokens", :lower},
    {:total_tokens, "Total tokens", :lower},
    {:cache_read_tokens, "Cache read", :higher},
    {:estimated_cost_usd, "Cost", :lower}
  ]

  @doc """
  Metric deltas between an original log and a replay, for the compare UI.

  nil metrics on either side yield `direction: :unknown` — never treated
  as an improvement.
  """
  def deltas(original, replay) do
    Enum.map(@metrics, fn {key, label, better} ->
      orig = to_number(Map.get(original, key))
      repl = to_number(Map.get(replay, key))

      %{
        key: key,
        label: label,
        original: Map.get(original, key),
        replay: Map.get(replay, key),
        delta_pct: delta_pct(orig, repl),
        direction: direction(orig, repl, better)
      }
    end)
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: {:error, :invalid_model}

  defp normalize_effort(nil), do: nil
  defp normalize_effort(""), do: nil
  defp normalize_effort(effort) when is_binary(effort), do: String.trim(effort)
  defp normalize_effort(_effort), do: :invalid

  # Mirrors RoutingStep's validation (length only — models.dev knows efforts
  # the static list doesn't, so membership isn't enforced)
  defp validate_effort(nil), do: :ok
  defp validate_effort(effort) when is_binary(effort) and byte_size(effort) <= 32, do: :ok
  defp validate_effort(_effort), do: {:error, :invalid_reasoning_effort}

  # Reasoning controls belong to the model that was asked, not to the
  # conversation. `thinking: {"type": "adaptive"}` is a 400 on a Claude model
  # that predates adaptive thinking, so carrying the source's block to a
  # different model means the candidate never answers at all — the request
  # is refused before it is read.
  #
  # Kept when the model is unchanged: that is a genuine re-run, and there
  # fidelity is the whole point.
  @reasoning_params ~w(reasoning_effort thinking reasoning)

  defp drop_reasoning_params(request, effort, source_model, target_model) do
    cond do
      effort not in [nil, ""] -> drop_reasoning(request)
      target_model != source_model -> drop_reasoning(request)
      true -> request
    end
  end

  # `output_config` also carries structured outputs, so only its effort key
  # goes — dropping the object would lose the schema the caller asked for.
  defp drop_reasoning(request) do
    request
    |> Map.drop(@reasoning_params)
    |> case do
      %{"output_config" => config} = dropped when is_map(config) ->
        Map.put(dropped, "output_config", Map.delete(config, "effort"))

      dropped ->
        dropped
    end
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_request_body}
    end
  end

  defp decode_body(_body), do: {:error, :invalid_request_body}

  defp ensure_messages(%{"messages" => [_ | _] = messages}) when is_list(messages), do: :ok
  defp ensure_messages(_decoded), do: {:error, :missing_messages}

  # truncation_flags can't distinguish request-side from response-side
  # truncation, and a truncated response doesn't hurt replay fidelity —
  # so block only when the stored request itself carries the markers
  # written by Proxy.truncate_body/1.
  defp ensure_not_truncated(%{"messages" => messages}) do
    truncated? =
      Enum.any?(messages, fn message ->
        case message["content"] do
          content when is_binary(content) -> content_truncated?(content)
          _ -> false
        end
      end)

    if truncated?, do: {:error, :truncated}, else: :ok
  end

  defp content_truncated?(content) do
    String.ends_with?(content, "... [truncated]") or
      (String.starts_with?(content, "[base64 data: ") and
         String.ends_with?(content, "bytes truncated]"))
  end

  defp fetch_persisted(request_id) do
    case Logs.get_log_by_request_id(request_id) do
      %RequestLog{} = log -> {:ok, log}
      nil -> {:error, :log_not_persisted}
    end
  end

  defp plan_type_for(provider_key) do
    if Providers.subscription_key?(provider_key), do: "coding", else: "standard"
  end

  defp offerable_key?(%{provider_slug: "test_provider"}) do
    Application.get_env(:dodo_router, :env) == :test
  end

  defp offerable_key?(_key), do: true

  # Plan-specific catalogs (e.g. moonshot_coding) live under the KEY slug;
  # they take precedence over the provider's global entries on id collisions.
  defp models_for(key, provider) do
    catalog_provider = normalize_models_provider(provider)

    plan_catalog =
      if key.provider_slug == catalog_provider,
        do: [],
        else: Models.offerable_models(key.provider_slug)

    # Offerable, not every row we hold: a model models.dev stopped listing is
    # retired at the provider, and offering it spends a run to discover that.
    catalog = plan_catalog ++ Models.offerable_models(catalog_provider)

    catalog_entries =
      Enum.map(catalog, fn model ->
        %{
          id: model.model_id,
          display_name: model.display_name,
          input_price: model.input_price_per_million,
          output_price: model.output_price_per_million,
          max_input_tokens: model.max_input_tokens
        }
      end)

    # The adapter's own list stands in only when we have no catalog for this
    # provider. Appended to a real one it reintroduces models the adapter has
    # outlived — they are not rows, so no catalog filter can see them.
    registry_entries =
      if catalog_entries == [] do
        provider
        |> Registry.available_models()
        |> Enum.map(
          &%{id: &1, display_name: &1, input_price: nil, output_price: nil, max_input_tokens: nil}
        )
      else
        []
      end

    (catalog_entries ++ registry_entries)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp normalize_models_provider("openai-codex"), do: "openai"
  defp normalize_models_provider(slug), do: slug

  defp to_number(nil), do: nil
  defp to_number(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_number(value) when is_number(value), do: value

  defp delta_pct(orig, repl) when is_number(orig) and is_number(repl) and orig != 0 do
    Float.round((repl - orig) / orig * 100, 1)
  end

  defp delta_pct(_orig, _repl), do: nil

  defp direction(orig, repl, _better) when is_nil(orig) or is_nil(repl), do: :unknown
  defp direction(orig, repl, _better) when orig == repl, do: :even
  defp direction(orig, repl, :lower) when repl < orig, do: :better
  defp direction(_orig, _repl, :lower), do: :worse
  defp direction(orig, repl, :higher) when repl > orig, do: :better
  defp direction(_orig, _repl, :higher), do: :worse
end
