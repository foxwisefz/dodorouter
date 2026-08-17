defmodule DodoRouterWeb.EvalLive.New do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs
  alias DodoRouter.Logs.Evaluation
  alias DodoRouter.Providers
  alias DodoRouter.Recordings
  alias DodoRouter.Replays
  alias DodoRouter.Routers
  alias DodoRouter.TextDiff

  @impl true
  def mount(%{"recording_id" => recording_id, "router_id" => router_id}, _session, socket) do
    user = socket.assigns.current_user
    router = Routers.get_router!(user, router_id)
    recording = Recordings.get_recording(user, recording_id)

    cond do
      is_nil(recording) or recording.router_id != router.id ->
        {:ok, redirect(socket, to: ~p"/routers/#{router.id}/recordings")}

      true ->
        case Evaluations.source_logs_from_recording(recording) do
          %{selected: []} = sample ->
            {:ok,
             socket
             |> put_flash(:error, no_replayable_message(sample))
             |> redirect(to: ~p"/routers/#{router.id}/recordings/#{recording.id}")}

          %{selected: logs} = sample ->
            setup(socket, %{}, logs, recording, sample)
        end
    end
  end

  def mount(%{"id" => id} = params, _session, socket) do
    log = Logs.get_log!(socket.assigns.current_user, id)
    setup(socket, params, [log], nil, nil)
  end

  # Everything below the source selection is one builder: the recording
  # entry point differs from the single-log one only in where the source
  # logs came from and where "back" leads.
  defp setup(socket, params, source_logs, recording, sample) do
    [log | _] = source_logs
    targets = Replays.list_targets(socket.assigns.current_user)

    target_lookup =
      for target <- targets, model <- target.models, into: %{} do
        model_id = model[:id] || model["id"] || model

        {"#{target.provider_key.id}|#{model_id}",
         %{
           "provider_key_id" => target.provider_key.id,
           "provider" => target.provider,
           "provider_name" => target.display_name,
           "model" => model_id
         }}
      end

    provider_options = Enum.map(targets, &{key_label(&1), &1.provider_key.id})
    provider_keys_by_id = Map.new(targets, &{&1.provider_key.id, &1.provider_key})

    models_by_provider =
      Map.new(targets, fn target -> {target.provider_key.id, model_options(target)} end)

    source = duplication_source(socket.assigns.current_user, params["from"])

    form =
      prefill_evaluation(source, log, recording)
      |> Evaluations.change_evaluation()
      |> to_form()

    selected_targets =
      case source do
        nil ->
          # Start from the models that actually served these logs: a benchmark
          # without the incumbent has numbers but no baseline, and the form
          # should not ask every user to remember the guide's first rule. A
          # recording can span models, so every distinct serving pair is
          # seeded, not just the anchor's.
          source_logs
          |> Enum.map(&Replays.incumbent_target/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn %{provider_key_id: key_id, model: model} -> "#{key_id}|#{model}" end)
          |> Enum.uniq()
          |> Enum.filter(&Map.has_key?(target_lookup, &1))

        source ->
          source.candidate_targets
          |> Enum.map(&"#{&1["provider_key_id"]}|#{&1["model"]}")
          |> Enum.filter(&Map.has_key?(target_lookup, &1))
      end

    judge_target = judge_target_value(source, target_lookup)

    {:ok,
     socket
     |> assign(:page_title, "Create evaluation")
     |> assign(:log, log)
     |> assign(:source_logs, source_logs)
     |> assign(:recording, recording)
     |> assign(:sample, sample)
     |> assign(:target_lookup, target_lookup)
     |> assign(:target_labels, target_labels(targets))
     |> assign(:provider_options, provider_options)
     |> assign(:provider_keys_by_id, provider_keys_by_id)
     |> assign(:judge_on_subscription?, false)
     |> assign(:models_by_provider, models_by_provider)
     |> assign(:picker_models, [])
     |> assign(:picker_form, to_form(%{"provider" => "", "target" => ""}, as: :picker))
     |> assign(:selected_targets, selected_targets)
     |> assign(:recent_judges, recent_judges(socket.assigns.current_user, target_lookup))
     |> assign_judge(judge_target)
     |> assign(:variants, display_variants(source && source.prompt_variants))
     # A variant is authored against a request, so the request is on the
     # page. Patch indexes address the anchor's messages; for a recording
     # the same index addresses every sampled request, which the panel says.
     |> assign(:source_messages, Replays.source_messages(log))
     |> assign(:served_system_prompt, Replays.served_system_prompt(log))
     |> assign(:show_source_request, false)
     |> assign(:form, form)}
  end

  # A judge is one key and one model, so it is picked the way a candidate is:
  # a short list of keys, then that key's models. One flat key×model select
  # is every model the account can reach, repeated per key.
  defp assign_judge(socket, nil), do: assign_judge_key(socket, nil)

  defp assign_judge(socket, target) do
    key_id = target |> String.split("|", parts: 2) |> List.first()

    socket
    |> assign_judge_key(key_id)
    |> assign(:judge_target_value, target)
  end

  defp assign_judge_key(socket, key_id) do
    socket
    |> assign(:judge_on_subscription?, subscription_judge?(socket, key_id))
    |> assign(:judge_key, key_id)
    |> assign(:judge_models, Map.get(socket.assigns.models_by_provider, key_id, []))
    |> assign(:judge_target_value, nil)
  end

  # The model select only ever offers one key's models, so a model left over
  # from the previously selected key is dropped rather than silently billed
  # to the new one.
  defp sync_judge(socket, params) do
    key = blank_to_nil(params["judge_key"])
    target = blank_to_nil(params["judge_target"])

    cond do
      is_nil(key) -> assign_judge(socket, nil)
      target && String.starts_with?(target, key <> "|") -> assign_judge(socket, target)
      true -> assign_judge_key(socket, key)
    end
  end

  # Reads the key off the already-loaded targets rather than re-querying: the
  # picker only ever offers keys from that list.
  defp subscription_judge?(_socket, nil), do: false

  defp subscription_judge?(socket, key_id) do
    socket.assigns.provider_keys_by_id |> Map.get(key_id) |> Providers.subscription_key?()
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # Past picks are only offered while the key and model are both still
  # configured — a chip that silently resolves to a deleted key would fail
  # at benchmark time, long after the click.
  defp recent_judges(user, target_lookup) do
    user
    |> Evaluations.recent_judges()
    |> Enum.map(&"#{&1.provider_key_id}|#{&1.model}")
    |> Enum.filter(&Map.has_key?(target_lookup, &1))
  end

  defp target_labels(targets) do
    for target <- targets, model <- target.models, into: %{} do
      model_id = model[:id] || model["id"] || model
      model_name = model[:display_name] || model["display_name"] || model_id
      {"#{target.provider_key.id}|#{model_id}", "#{key_label(target)} · #{model_name}"}
    end
  end

  # One label for a provider key, shared with every other picker. This used
  # to build its own from the *adapter's* display name, so a metered
  # Moonshot key and a Moonshot coding-plan key both read "Moonshot · Key 1"
  # in the same dropdown.
  defp key_label(target) do
    DodoRouterWeb.ProviderComponents.provider_key_option_label(target.provider_key)
  end

  defp model_options(target) do
    Enum.map(target.models, fn model ->
      model_id = model[:id] || model["id"] || model
      model_name = model[:display_name] || model["display_name"] || model_id
      {model_name, "#{target.provider_key.id}|#{model_id}"}
    end)
  end

  # Duplication seeds the builder from an existing evaluation instead of
  # editing it in place: past scores are only meaningful relative to the
  # rubric and targets that produced them, so a changed setup is a new
  # evaluation. Scoped to the current user; anything else prefill-fails
  # silently to a blank builder.
  defp duplication_source(_user, nil), do: nil
  defp duplication_source(user, from_id), do: Evaluations.get_evaluation(user, from_id)

  defp back_path(%Recordings.Recording{} = recording, _log),
    do: ~p"/routers/#{recording.router_id}/recordings/#{recording.id}"

  defp back_path(nil, log), do: ~p"/logs/#{log.id}"

  defp excluded_summary(excluded),
    do: Enum.map_join(excluded, ", ", fn {reason, count} -> "#{count} #{reason}" end)

  # The form field arrives as a string mid-edit; the planned-runs math should
  # not crash on a half-typed value.
  defp reps_value(form) do
    case form[:repetitions].value do
      n when is_integer(n) ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _rest} -> n
          :error -> 1
        end

      _ ->
        1
    end
  end

  defp no_replayable_message(%{total: 0}), do: "This recording has no captured requests yet."

  defp no_replayable_message(%{excluded: excluded}) do
    reasons = Enum.map_join(excluded, ", ", fn {reason, count} -> "#{count} #{reason}" end)
    "None of this recording's captured requests can be replayed (#{reasons})."
  end

  defp prefill_evaluation(nil, _log, %Recordings.Recording{} = recording) do
    %Evaluation{name: String.slice("Benchmark of #{recording.name || "recording"}", 0, 120)}
  end

  defp prefill_evaluation(nil, log, nil) do
    %Evaluation{name: "Evaluation of #{String.slice(log.request_id, 0, 8)}"}
  end

  defp prefill_evaluation(source, _log, _recording) do
    %Evaluation{
      name: String.slice("Copy of #{source.name}", 0, 120),
      criteria: source.criteria,
      good_examples: source.good_examples,
      bad_examples: source.bad_examples,
      judge_model: source.judge_model,
      judge_provider_key_id: source.judge_provider_key_id,
      prompt_variants: source.prompt_variants || [],
      repetitions: source.repetitions
    }
  end

  defp judge_target_value(nil, _target_lookup), do: nil

  defp judge_target_value(source, target_lookup) do
    value = "#{source.judge_provider_key_id}|#{source.judge_model}"
    if Map.has_key?(target_lookup, value), do: value
  end

  @impl true
  def handle_event("validate", %{"evaluation" => params}, socket) do
    variants =
      params
      |> variants_from_params()
      |> seed_patch_contents(socket.assigns.variants, socket.assigns.source_messages)

    params =
      params
      |> Map.put("prompt_variants", variants)
      |> prepare_params(socket.assigns.target_lookup)

    form =
      %Evaluation{}
      |> Evaluations.change_evaluation(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:selected_targets, params["candidate_target_values"] || [])
     # The variant rows are rendered from what was typed, not from the
     # changeset: a shape the schema rejects (two variants named the same)
     # never becomes a change, and reading the field back would erase the
     # user's text at exactly the keystroke that told them it was wrong.
     |> assign(:variants, variants)
     |> sync_judge(params)}
  end

  def handle_event("add_variant", _params, socket) do
    {:noreply,
     socket
     # Adding the first variant is the moment the request stops being
     # background and becomes the thing being edited, so it opens itself
     # rather than waiting to be found.
     |> assign(
       :show_source_request,
       socket.assigns.variants == [] or socket.assigns.show_source_request
     )
     |> assign(:variants, socket.assigns.variants ++ [blank_variant()])}
  end

  def handle_event("toggle_source_request", _params, socket) do
    {:noreply, assign(socket, :show_source_request, !socket.assigns.show_source_request)}
  end

  # A prompt variant is almost always an edit of the real prompt, not one
  # written from memory — so the real one is one click away, and the diff
  # under the box then shows exactly what the edit did.
  def handle_event("use_served_prompt", %{"index" => index}, socket) do
    {:noreply,
     update_variant(socket, index, fn variant ->
       Map.put(variant, "system_prompt", socket.assigns.served_system_prompt || "")
     end)}
  end

  def handle_event("remove_variant", %{"index" => index}, socket) do
    {:noreply, update_at(socket, index, &List.delete_at/2)}
  end

  def handle_event("add_patch", %{"index" => index}, socket) do
    {:noreply,
     update_variant(socket, index, fn variant ->
       Map.update(variant, "message_patches", [blank_patch()], &(&1 ++ [blank_patch()]))
     end)}
  end

  def handle_event("remove_patch", %{"index" => index, "patch" => patch}, socket) do
    {:noreply,
     update_variant(socket, index, fn variant ->
       Map.update(variant, "message_patches", [], &delete_at(&1, patch))
     end)}
  end

  def handle_event("pick_recent_judge", %{"target" => target}, socket) do
    if Map.has_key?(socket.assigns.target_lookup, target) do
      {:noreply, assign_judge(socket, target)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_provider", %{"picker" => %{"provider" => provider}}, socket) do
    {:noreply,
     socket
     |> assign(:picker_models, Map.get(socket.assigns.models_by_provider, provider, []))
     |> assign(:picker_form, to_form(%{"provider" => provider, "target" => ""}, as: :picker))}
  end

  def handle_event("add_candidate", %{"picker" => picker}, socket) do
    target = picker["target"]

    selected =
      if Map.has_key?(socket.assigns.target_lookup, target) do
        Enum.uniq(socket.assigns.selected_targets ++ [target])
      else
        socket.assigns.selected_targets
      end

    {:noreply,
     socket
     |> assign(:selected_targets, selected)
     |> assign(
       :picker_form,
       to_form(%{"provider" => picker["provider"] || "", "target" => ""}, as: :picker)
     )}
  end

  def handle_event("remove_candidate", %{"target" => target}, socket) do
    {:noreply,
     assign(socket, :selected_targets, List.delete(socket.assigns.selected_targets, target))}
  end

  def handle_event("save", %{"evaluation" => params}, socket) do
    # Every path out of here re-renders the rows, and two of them are
    # refusals — so the typed variants are taken from the submission before
    # anything can reject it.
    socket = assign(socket, :variants, variants_from_params(params))

    params =
      params
      |> prepare_params(socket.assigns.target_lookup)
      |> add_sources(socket.assigns.recording, socket.assigns.source_logs)

    with :ok <- check_next_action(socket, params),
         :ok <- check_message_patches(socket, params) do
      save_evaluation(socket, params)
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp update_variant(socket, index, fun) do
    update_at(socket, index, fn variants, i ->
      List.replace_at(variants, i, fun.(Enum.at(variants, i)))
    end)
  end

  # A row index arrives as a string from the DOM. Negative indexes are how
  # `List` addresses the tail, so an unparseable one must drop the update
  # rather than fall through to deleting the last row the user has.
  defp update_at(socket, index, fun) do
    variants = socket.assigns.variants

    case index_within(index, variants) do
      nil -> socket
      i -> assign(socket, :variants, fun.(variants, i))
    end
  end

  defp delete_at(list, index) do
    case index_within(index, list) do
      nil -> list
      i -> List.delete_at(list, i)
    end
  end

  defp index_within(index, list) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i >= 0 -> if i < length(list), do: i
      _ -> nil
    end
  end

  defp blank_variant, do: %{"name" => "", "system_prompt" => "", "message_patches" => []}
  defp blank_patch, do: %{"index" => "", "content" => ""}

  defp check_next_action(socket, params) do
    if params["comparison_mode"] == "next_action" and
         Enum.any?(socket.assigns.source_logs, &Evaluations.next_action_blocker/1) do
      {:error,
       "Next-action mode compares against the recorded response, and at least one source request has none on record. Use rubric mode for this set."}
    else
      :ok
    end
  end

  # An index with no message behind it fails minutes into a paid benchmark,
  # so it is refused here — named, since the user cannot see which of a
  # recording's requests is short.
  defp check_message_patches(socket, params) do
    case Evaluations.message_patch_blocker(params["prompt_variants"], socket.assigns.source_logs) do
      nil ->
        :ok

      blocker ->
        {:error,
         "Variant #{inspect(blocker.variant)} patches a message index that at least one source " <>
           "request does not have. Indexes are 0-based into that request's messages as served."}
    end
  end

  defp save_evaluation(socket, params) do
    case Evaluations.create_evaluation(socket.assigns.current_user, socket.assigns.log, params) do
      {:ok, evaluation} ->
        # Enqueue here, from the explicit save action: a run flag in the
        # destination URL would re-trigger a paid benchmark on refresh.
        {kind, message} =
          Evaluations.enqueue(socket.assigns.current_user, evaluation) |> enqueue_flash()

        {:noreply,
         socket
         |> put_flash(kind, message)
         |> push_navigate(to: ~p"/evals/#{evaluation.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # A multi-log benchmark can genuinely hit the run cap or a blocked key at
  # enqueue time; the evaluation still exists, so navigate to it either way
  # and say why nothing is running rather than flashing "queued" over a
  # refusal.
  defp enqueue_flash(:ok), do: {:info, "Benchmark queued"}

  defp enqueue_flash({:error, {:too_many_runs, planned, max}}),
    do:
      {:error,
       "Created, but not started: #{planned} runs planned (logs × candidates × repetitions); the cap is #{max}. Lower repetitions or remove candidates, then run it from this page."}

  defp enqueue_flash({:error, {:judge_key_unusable, blocker}}),
    do:
      {:error, "Created, but not started: the judge's key #{blocker.label} is #{blocker.status}."}

  defp enqueue_flash({:error, {:candidates_unusable, _blockers}}),
    do: {:error, "Created, but not started: every candidate's key is currently blocked."}

  defp enqueue_flash({:error, _other}),
    do: {:error, "Created, but the benchmark could not be started. Run it from this page."}

  defp add_sources(params, %Recordings.Recording{} = recording, source_logs) do
    params
    |> Map.put("source_log_ids", Enum.map(source_logs, & &1.id))
    |> Map.put("recording_id", recording.id)
  end

  defp add_sources(params, nil, _source_logs), do: params

  defp split_target(%{"judge_target" => target} = params) do
    case String.split(target, "|", parts: 2) do
      [key_id, model] ->
        params
        |> Map.put("judge_provider_key_id", key_id)
        |> Map.put("judge_model", model)

      _ ->
        params
    end
  end

  defp split_target(params), do: params

  defp prepare_params(params, target_lookup) do
    selected = params["candidate_target_values"] || []

    params
    |> split_target()
    |> Map.put(
      "candidate_targets",
      Enum.map(selected, &Map.get(target_lookup, &1)) |> Enum.reject(&is_nil/1)
    )
    |> Map.put("prompt_variants", params |> variants_from_params() |> typed_variants())
  end

  # Nested form params arrive index-keyed; the schema and the rendered rows
  # both want them in the order the user sees.
  defp variants_from_params(params) do
    params
    |> Map.get("prompt_variants")
    |> indexed_list()
    |> Enum.map(fn variant ->
      %{
        "name" => to_string(variant["name"] || ""),
        "system_prompt" => to_string(variant["system_prompt"] || ""),
        "message_patches" =>
          variant
          |> Map.get("message_patches")
          |> indexed_list()
          |> Enum.map(
            &%{
              "index" => to_string(&1["index"] || ""),
              "content" => to_string(&1["content"] || "")
            }
          )
      }
    end)
  end

  # Choosing a message is the moment its text is known, so that is when the
  # replacement box gets seeded with it: authoring a patch becomes editing
  # the real message rather than retyping it from a preview. Only when the
  # chosen index actually changed, and only into an empty box — re-seeding
  # would undo the edit the user came here to make.
  defp seed_patch_contents(variants, previous, source_messages) do
    variants
    |> Enum.with_index()
    |> Enum.map(fn {variant, index} ->
      was = Map.get(Enum.at(previous, index) || %{}, "message_patches", [])

      patches =
        variant["message_patches"]
        |> Enum.with_index()
        |> Enum.map(fn {patch, patch_index} ->
          previous_index = Map.get(Enum.at(was, patch_index) || %{}, "index")

          if patch["index"] != previous_index and patch["content"] == "" do
            %{patch | "content" => source_message_content(source_messages, patch["index"])}
          else
            patch
          end
        end)

      %{variant | "message_patches" => patches}
    end)
  end

  defp source_message_content(source_messages, index) do
    case Enum.find(source_messages, &(to_string(&1.index) == to_string(index))) do
      nil -> ""
      message -> message.content
    end
  end

  defp indexed_list(%{} = map) do
    map
    |> Enum.filter(fn {_key, value} -> is_map(value) end)
    |> Enum.sort_by(fn {key, _value} ->
      case Integer.parse(to_string(key)) do
        {index, _rest} -> index
        :error -> 0
      end
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp indexed_list(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp indexed_list(_other), do: []

  # What the replay will actually apply. A blank system prompt is "as
  # served" (nil), not an empty prompt — that is how a baseline sits in the
  # comparison under its own name — and a variant with no patch rows
  # carries no `message_patches` key at all.
  defp typed_variants(variants) do
    Enum.map(variants, fn variant ->
      %{
        "name" => String.trim(variant["name"] || ""),
        "system_prompt" => blank_to_nil(variant["system_prompt"])
      }
      |> put_patches(variant["message_patches"])
    end)
  end

  defp put_patches(variant, patches) do
    case Enum.reject(patches || [], &blank_patch?/1) do
      [] -> variant
      patches -> Map.put(variant, "message_patches", Enum.map(patches, &typed_patch/1))
    end
  end

  # An untouched row the user added and then ignored is not a patch; a
  # half-filled one is, and has to reach the changeset so it can say so.
  defp blank_patch?(patch),
    do: blank_to_nil(patch["index"]) == nil and blank_to_nil(patch["content"]) == nil

  defp typed_patch(patch) do
    index =
      case Integer.parse(to_string(patch["index"] || "")) do
        {index, ""} -> index
        _ -> to_string(patch["index"] || "")
      end

    %{"index" => index, "content" => patch_content(patch["content"])}
  end

  # Multimodal content is a block array, which the MCP path can send and a
  # textarea cannot. Duplicating such a variant would otherwise silently
  # rewrite the array into a JSON string, so text that parses back to a
  # list is restored as one.
  defp patch_content(content) do
    content = to_string(content || "")

    case Jason.decode(content) do
      {:ok, blocks} when is_list(blocks) -> blocks
      _ -> content
    end
  end

  # Duplication seeds the rows from a stored evaluation, which holds the
  # typed shape: nil system prompt reads as the empty textarea it came from.
  defp display_variants(variants) when is_list(variants) do
    Enum.map(indexed_list(variants), fn variant ->
      %{
        "name" => to_string(variant["name"] || ""),
        "system_prompt" => to_string(variant["system_prompt"] || ""),
        "message_patches" =>
          variant
          |> Map.get("message_patches")
          |> indexed_list()
          |> Enum.map(
            &%{
              "index" => to_string(&1["index"] || ""),
              "content" => display_content(&1["content"])
            }
          )
      }
    end)
  end

  defp display_variants(_variants), do: []

  defp display_content(content) when is_list(content), do: Jason.encode!(content)
  defp display_content(content), do: to_string(content || "")

  defp variant_errors(form), do: Enum.map(form[:prompt_variants].errors, &translate_error/1)

  # The message select is the index field: an index is a position in a list
  # the author can now read, so it is chosen rather than remembered.
  defp message_options(source_messages) do
    Enum.map(source_messages, &{"#{&1.index} · #{&1.role} · #{preview(&1.content)}", &1.index})
  end

  defp preview(content) do
    content = content |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(content) > 60, do: String.slice(content, 0, 60) <> "…", else: content
  end

  defp source_message(source_messages, index),
    do: Enum.find(source_messages, &(to_string(&1.index) == to_string(index)))

  # Nothing to show until the two sides differ; an unchanged variant is a
  # variant the author has not written yet, not a diff of nothing.
  defp prompt_diff(served, prompt) do
    prompt = to_string(prompt)

    if String.trim(prompt) != "" and prompt != to_string(served || ""),
      do: TextDiff.diff(served, prompt)
  end

  defp patch_diff(nil, _content), do: nil

  defp patch_diff(%{content: served}, content) do
    content = to_string(content)
    if content != served, do: TextDiff.diff(served, content)
  end

  # Everything the template needs about a variant, computed once: HEEx can
  # only read assigns, and a diff is not something to recompute inside a
  # comprehension.
  defp variant_views(variants, source_messages, served_prompt) do
    variants
    |> Enum.with_index()
    |> Enum.map(fn {variant, index} ->
      %{
        index: index,
        name: variant["name"],
        system_prompt: variant["system_prompt"],
        prompt_diff: prompt_diff(served_prompt, variant["system_prompt"]),
        patches: patch_views(variant["message_patches"] || [], source_messages)
      }
    end)
  end

  defp patch_views(patches, source_messages) do
    patches
    |> Enum.with_index()
    |> Enum.map(fn {patch, index} ->
      source = source_message(source_messages, patch["index"])

      %{
        index: index,
        message_index: patch["index"],
        content: patch["content"],
        source: source,
        diff: patch_diff(source, patch["content"])
      }
    end)
  end

  # A diff whose inputs were too large to align comes back with no segments
  # — saying so beats an empty box that reads as "nothing changed".
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :diff, :map, required: true

  defp change_preview(assigns) do
    ~H"""
    <div id={@id} class="mt-2 rounded-lg border border-base-300/60 bg-base-100/70 p-3">
      <p class="mb-1.5 text-xs font-medium text-base-content/45">{@label}</p>
      <.diff_block
        :if={@diff.segments != []}
        segments={@diff.segments}
        mono
        eq_class="text-base-content/40"
        class="max-h-64 overflow-y-auto"
      />
      <p :if={@diff.segments == []} class="text-xs text-base-content/45">
        Both sides are too large to line up word by word.
      </p>
    </div>
    """
  end

  # A factor of one multiplies nothing, so naming it only lengthens the
  # sentence — except for models and repetitions, which are the two the
  # user is choosing right here.
  defp run_plan(source_logs, variants, targets, repetitions) do
    factors = [
      {length(source_logs), "request", "requests"},
      {max(length(variants), 1), "prompt variant", "prompt variants"},
      {max(length(targets), 1), "model", "models"},
      {repetitions, "repetition", "repetitions"}
    ]

    shown =
      Enum.reject(factors, fn {count, singular, _plural} ->
        count <= 1 and singular in ["request", "prompt variant"]
      end)

    %{
      sentence:
        Enum.map_join(shown, " × ", fn {count, singular, plural} ->
          "#{count} #{if count == 1, do: singular, else: plural}"
        end),
      total: Enum.reduce(factors, 1, fn {count, _singular, _plural}, acc -> acc * count end)
    }
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :run_plan,
        run_plan(
          assigns.source_logs,
          assigns.variants,
          assigns.selected_targets,
          reps_value(assigns.form)
        )
      )
      |> assign(
        :variant_views,
        variant_views(assigns.variants, assigns.source_messages, assigns.served_system_prompt)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl space-y-6">
        <div class="flex items-center gap-4">
          <.link
            navigate={back_path(@recording, @log)}
            class="btn btn-ghost btn-square"
            id="eval-back-link"
          >
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">
              New evaluation
            </p>
            <h1 class="text-3xl font-semibold tracking-tight">
              {if @recording,
                do: "Benchmark this recording's traffic",
                else: "Turn this request into a quality test"}
            </h1>
            <p class="mt-1 text-sm text-base-content/55">
              {if @recording,
                do: "Every candidate model answers every sampled request.",
                else: "The request and response are preserved as judge evidence."}
            </p>
          </div>
        </div>

        <div
          :if={@recording}
          id="eval-recording-source"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm"
        >
          <div class="flex flex-wrap items-center gap-6 text-sm">
            <div>
              <span class="text-base-content/45">Recording</span>
              <div class="font-medium">{@recording.name || "Recording"}</div>
            </div>
            <div>
              <span class="text-base-content/45">Source requests</span>
              <div>
                <span class="font-semibold">{length(@source_logs)}</span>
                <span class="text-base-content/45">of {@sample.total} captured</span>
              </div>
            </div>
            <div :if={@sample.evaluable > length(@source_logs)} class="text-base-content/55">
              Sampled evenly across the capture — {@sample.evaluable} were replayable, an
              evaluation holds at most {length(@source_logs)}.
            </div>
            <div :if={@sample.excluded != %{}} class="text-base-content/55">
              Not replayable: {excluded_summary(@sample.excluded)}.
            </div>
          </div>
        </div>

        <div
          :if={is_nil(@recording)}
          id="eval-source"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm"
        >
          <div class="flex flex-wrap gap-6 text-sm">
            <div>
              <span class="text-base-content/45">Model</span>
              <div class="font-mono">{@log.final_model}</div>
            </div>
            <div>
              <span class="text-base-content/45">Provider</span>
              <div>{@log.final_provider}</div>
            </div>
            <div>
              <span class="text-base-content/45">Latency</span>
              <div>{@log.latency_ms || "—"} ms</div>
            </div>
          </div>
        </div>

        <section
          id="candidate-targets"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
        >
          <div class="mb-4 flex items-end justify-between">
            <div>
              <p class="text-xs font-semibold uppercase tracking-wider text-primary">Step 1</p>
              <h2 class="text-lg font-semibold">Candidate models</h2>
              <p class="text-sm text-base-content/50">
                {if @recording,
                  do: "Each selected model will answer all #{length(@source_logs)} sampled requests.",
                  else: "Each selected model will answer the source request."}
              </p>
            </div>
          </div>
          <.form
            for={@picker_form}
            id="candidate-picker-form"
            phx-change="pick_provider"
            phx-submit="add_candidate"
            class="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
          >
            <.input
              field={@picker_form[:provider]}
              type="select"
              label="Provider"
              options={@provider_options}
              prompt="Choose provider"
            />
            <.input
              field={@picker_form[:target]}
              type="select"
              label="Model"
              options={@picker_models}
              prompt="Choose model"
              disabled={@picker_models == []}
            />
            <button
              id="add-candidate-button"
              type="submit"
              class="btn btn-primary mb-2 gap-2"
              disabled={@picker_models == []}
            >
              <.icon name="hero-plus" class="size-4" /> Add
            </button>
          </.form>
          <div id="selected-candidates" class="mt-5 space-y-2">
            <p
              :if={@selected_targets == []}
              class="rounded-xl border border-dashed border-base-300 px-4 py-6 text-center text-sm text-base-content/40"
            >
              No candidate models selected yet.
            </p>
            <div
              :for={target_value <- @selected_targets}
              class="flex items-center justify-between rounded-xl border border-base-300/70 bg-base-200/40 px-4 py-3"
            >
              <div class="flex items-center gap-3">
                <span class="grid size-8 place-items-center rounded-lg bg-primary/10 text-primary">
                  <.icon name="hero-cpu-chip" class="size-4" />
                </span>
                <div>
                  <div class="text-sm font-semibold">{@target_lookup[target_value]["model"]}</div>
                  <div class="text-xs text-base-content/45">
                    {@target_lookup[target_value]["provider_name"]}
                  </div>
                </div>
              </div>
              <button
                type="button"
                phx-click="remove_candidate"
                phx-value-target={target_value}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Remove candidate"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>
        </section>

        <.form for={@form} id="eval-form" phx-change="validate" phx-submit="save" class="space-y-5">
          <input
            :for={target <- @selected_targets}
            type="hidden"
            name="evaluation[candidate_target_values][]"
            value={target}
          />
          <div class="grid gap-6">
            <.input field={@form[:name]} type="text" label="Evaluation name" />

            <section
              id="prompt-variants"
              class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
            >
              <p class="text-xs font-semibold uppercase tracking-wider text-primary">Step 2</p>
              <h2 class="text-lg font-semibold">
                Prompt variants
                <span class="ml-1 align-middle text-xs font-normal text-base-content/40">
                  optional
                </span>
              </h2>
              <p class="mb-4 text-sm text-base-content/50">
                Hold the model constant and vary the prompt. Every candidate answers every variant,
                against one rubric, ranked per model × variant. With none, the request is replayed
                exactly as it was served.
              </p>

              <div
                :if={@source_messages != []}
                id="source-request"
                class="mb-4 overflow-hidden rounded-xl border border-base-300/70 bg-base-200/30"
              >
                <button
                  type="button"
                  id="toggle-source-request"
                  phx-click="toggle_source_request"
                  class="flex w-full items-center gap-2 px-4 py-2.5 text-left text-sm transition hover:bg-base-200/60"
                >
                  <.icon
                    name={
                      if @show_source_request, do: "hero-chevron-down", else: "hero-chevron-right"
                    }
                    class="size-4 shrink-0 text-base-content/40"
                  />
                  <span class="font-medium">Request as served</span>
                  <span class="text-base-content/45">
                    {length(@source_messages)} messages{if length(@source_logs) > 1,
                      do: " · first of #{length(@source_logs)} sampled requests"}
                  </span>
                </button>
                <div :if={@show_source_request} class="border-t border-base-300/70">
                  <div
                    :for={message <- @source_messages}
                    class="flex gap-3 border-b border-base-300/40 px-4 py-2.5 last:border-b-0"
                  >
                    <span class="w-6 shrink-0 text-right font-mono text-xs text-base-content/35">
                      {message.index}
                    </span>
                    <span class="w-20 shrink-0 text-xs font-medium text-base-content/55">
                      {message.role}
                    </span>
                    <%!-- A real agent system prompt is thousands of lines; it scrolls
                    in place rather than pushing the form it belongs to off-screen. --%>
                    <span class="max-h-48 min-w-0 flex-1 overflow-y-auto whitespace-pre-wrap break-words font-mono text-xs text-base-content/70">
                      {message.content}
                    </span>
                  </div>
                  <p
                    :if={length(@source_logs) > 1}
                    class="border-t border-base-300/40 px-4 py-2.5 text-xs text-base-content/45"
                  >
                    A patch index addresses this position in <em>every</em>
                    sampled request, not just this one. Saving refuses any index a sampled request
                    is too short for.
                  </p>
                </div>
              </div>

              <p
                :if={@source_messages == []}
                id="source-request-unavailable"
                class="mb-4 rounded-xl border border-warning/40 bg-warning/5 px-4 py-3 text-xs text-base-content/70"
              >
                This request's body was not stored, so there is nothing to show or patch here — and
                nothing to replay either. Pick a request whose body is on record.
              </p>

              <p :for={message <- variant_errors(@form)} class="mb-3 text-sm text-error">
                {message}
              </p>

              <p
                :if={@variants == []}
                class="rounded-xl border border-dashed border-base-300 px-4 py-6 text-center text-sm text-base-content/40"
              >
                No variants — every candidate answers the request as served.
              </p>

              <div id="variant-list" class="space-y-4">
                <div
                  :for={view <- @variant_views}
                  id={"variant-#{view.index}"}
                  class="rounded-xl border border-base-300/70 bg-base-200/40 p-4"
                >
                  <div class="mb-2 flex items-center justify-between">
                    <p class="text-xs font-semibold uppercase tracking-wider text-base-content/45">
                      Variant {view.index + 1}
                    </p>
                    <button
                      type="button"
                      phx-click="remove_variant"
                      phx-value-index={view.index}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Remove variant"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                  <.input
                    id={"variant-#{view.index}-name"}
                    name={"evaluation[prompt_variants][#{view.index}][name]"}
                    value={view.name}
                    type="text"
                    label="Variant name"
                    placeholder="Names the ranking row — the judge never sees it"
                  />
                  <div class="mt-1 flex items-end justify-between gap-3">
                    <p class="text-xs text-base-content/55">
                      {if @served_system_prompt,
                        do: "System prompt — replaces the served one",
                        else: "System prompt — this request had none, so it is prepended"}
                    </p>
                    <button
                      :if={@served_system_prompt}
                      type="button"
                      id={"use-served-prompt-#{view.index}"}
                      phx-click="use_served_prompt"
                      phx-value-index={view.index}
                      class="btn btn-ghost btn-xs gap-1"
                    >
                      <.icon name="hero-document-duplicate" class="size-3" /> Start from served prompt
                    </button>
                  </div>
                  <.input
                    id={"variant-#{view.index}-system-prompt"}
                    name={"evaluation[prompt_variants][#{view.index}][system_prompt]"}
                    value={view.system_prompt}
                    type="textarea"
                    placeholder="Leave blank to score the request as served, under this name."
                  />
                  <.change_preview
                    :if={view.prompt_diff}
                    id={"variant-#{view.index}-prompt-diff"}
                    label="Served prompt → this variant"
                    diff={view.prompt_diff}
                  />

                  <div class="mt-3 rounded-lg border border-base-300/60 bg-base-100/70 p-3">
                    <div class="flex items-center justify-between gap-3">
                      <p class="text-xs font-medium text-base-content/55">Message patches</p>
                      <button
                        type="button"
                        id={"add-patch-#{view.index}"}
                        phx-click="add_patch"
                        phx-value-index={view.index}
                        class="btn btn-ghost btn-xs gap-1"
                        disabled={@source_messages == []}
                      >
                        <.icon name="hero-plus" class="size-3" /> Patch a message
                      </button>
                    </div>
                    <p :if={view.patches == []} class="mt-1 text-xs text-base-content/40">
                      Advanced. Replace one message's content while everything else stays exactly
                      what production sent — the same frozen history with one bit flipped, for
                      context transforms like "does compressing this tool result preserve the
                      reasoning?". Pick the message; its text opens for editing.
                    </p>
                    <div
                      :for={patch <- view.patches}
                      id={"variant-#{view.index}-patch-#{patch.index}"}
                      class="mt-2 rounded-lg border border-base-300/60 bg-base-200/40 p-3"
                    >
                      <div class="flex items-end gap-2">
                        <div class="min-w-0 flex-1">
                          <.input
                            id={"variant-#{view.index}-patch-#{patch.index}-index"}
                            name={
                              "evaluation[prompt_variants][#{view.index}][message_patches][#{patch.index}][index]"
                            }
                            value={patch.message_index}
                            type="select"
                            label="Message"
                            prompt="Choose a message to replace"
                            options={message_options(@source_messages)}
                          />
                        </div>
                        <button
                          type="button"
                          phx-click="remove_patch"
                          phx-value-index={view.index}
                          phx-value-patch={patch.index}
                          class="btn btn-ghost btn-xs btn-square mb-2"
                          aria-label="Remove message patch"
                        >
                          <.icon name="hero-x-mark" class="size-4" />
                        </button>
                      </div>
                      <p
                        :if={patch.source && !patch.source.text?}
                        class="mb-1 flex items-start gap-1.5 text-xs text-warning"
                      >
                        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-3.5 shrink-0" />
                        <span class="text-base-content/70">
                          This message was sent as content blocks, not plain text. Replacing it with
                          text changes its shape as well as its wording.
                        </span>
                      </p>
                      <.input
                        id={"variant-#{view.index}-patch-#{patch.index}-content"}
                        name={
                          "evaluation[prompt_variants][#{view.index}][message_patches][#{patch.index}][content]"
                        }
                        value={patch.content}
                        type="textarea"
                        label="Replacement content"
                      />
                      <.change_preview
                        :if={patch.diff}
                        id={"variant-#{view.index}-patch-#{patch.index}-diff"}
                        label={"Message #{patch.message_index} as served → this variant"}
                        diff={patch.diff}
                      />
                    </div>
                  </div>
                </div>
              </div>

              <button
                type="button"
                id="add-variant-button"
                phx-click="add_variant"
                class="btn btn-ghost btn-sm mt-4 gap-2 border border-base-300/70"
              >
                <.icon name="hero-plus" class="size-4" /> Add prompt variant
              </button>
            </section>

            <section
              id="judge-rubric"
              class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
            >
              <p class="text-xs font-semibold uppercase tracking-wider text-primary">Step 3</p>
              <h2 class="mb-4 text-lg font-semibold">Judge rubric</h2>
              <.input
                field={@form[:comparison_mode]}
                type="select"
                label="Judge framing"
                options={[
                  {"Rubric — score each answer against the criteria", "rubric"},
                  {"Next action — compare each answer to what production actually did", "next_action"}
                ]}
              />
              <p class="mb-3 text-xs text-base-content/45">
                Next action is the per-decision test for recorded agent traffic: same frozen
                history, two next moves, the judge states which is better. It needs each source
                request's served response on record.
              </p>
              <.input
                field={@form[:criteria]}
                type="textarea"
                label="Success criteria"
                placeholder="Describe what an excellent answer must do, avoid, and get right…"
              />
              <div class="grid gap-5 md:grid-cols-2">
                <.input
                  field={@form[:good_examples]}
                  type="textarea"
                  label="Good examples (optional)"
                  placeholder="One or more answers that should score highly"
                />
                <.input
                  field={@form[:bad_examples]}
                  type="textarea"
                  label="Bad examples (optional)"
                  placeholder="Examples and why they should lose points"
                />
              </div>
              <div class="mt-4 rounded-xl bg-primary/5 p-4 ring-1 ring-primary/10">
                <div :if={@recent_judges != []} id="recent-judges" class="mb-3">
                  <p class="mb-2 text-xs font-medium text-base-content/50">Recently used</p>
                  <div class="flex flex-wrap gap-2">
                    <button
                      :for={target <- @recent_judges}
                      type="button"
                      phx-click="pick_recent_judge"
                      phx-value-target={target}
                      class={[
                        "btn btn-xs gap-1.5 rounded-full font-normal transition",
                        if(@judge_target_value == target,
                          do: "btn-primary",
                          else: "btn-ghost border border-base-300/70 hover:border-primary/40"
                        )
                      ]}
                    >
                      <.icon name="hero-scale" class="size-3" />
                      {@target_labels[target]}
                    </button>
                  </div>
                </div>
                <div class="grid gap-3 sm:grid-cols-2">
                  <.input
                    name="evaluation[judge_key]"
                    type="select"
                    value={@judge_key}
                    label="Judge key"
                    options={@provider_options}
                    prompt="Choose provider key"
                  />
                  <.input
                    name="evaluation[judge_target]"
                    type="select"
                    value={@judge_target_value}
                    label="Judge model"
                    options={@judge_models}
                    prompt="Choose model"
                    disabled={@judge_models == []}
                    required
                  />
                </div>

                <p
                  :if={@judge_on_subscription?}
                  id="judge-billing-warning"
                  class="mt-3 flex items-start gap-2 rounded-xl border border-warning/40 bg-warning/5 p-3 text-xs text-base-content/70"
                >
                  <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-warning" />
                  <span>
                    <span class="font-medium text-base-content">
                      This key bills against a plan, not the API.
                    </span>
                    Subscription and coding-plan credentials are issued for a vendor's own coding
                    environment and can refuse calls made from anywhere else. A candidate that gets
                    refused costs you one data point; a judge that gets refused costs you every score
                    in the batch. Prefer a metered API key here.
                  </span>
                </p>
              </div>
            </section>

            <section
              id="run-plan"
              class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
            >
              <p class="text-xs font-semibold uppercase tracking-wider text-primary">Step 4</p>
              <h2 class="mb-4 text-lg font-semibold">Run plan</h2>
              <.input
                field={@form[:repetitions]}
                type="number"
                label="Repetitions per model"
                min="1"
                max="10"
              />
              <p class="text-xs text-base-content/45">
                Repeated generations reveal model consistency, not just one lucky answer.
              </p>
              <p
                :if={length(@source_logs) > 1 or @variants != []}
                id="planned-runs-note"
                class="mt-2 text-xs text-base-content/55"
              >
                {@run_plan.sentence} = <span class="font-semibold">{@run_plan.total}</span>
                judged runs. Benchmarks are capped at 300 runs.
              </p>
            </section>
          </div>
          <div class="flex justify-end">
            <button id="save-eval-button" type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-play" class="size-4" /> Create & run benchmark
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
