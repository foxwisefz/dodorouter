defmodule DodoRouterWeb.EvalLive.New do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs
  alias DodoRouter.Logs.Evaluation
  alias DodoRouter.Providers
  alias DodoRouter.Recordings
  alias DodoRouter.Replays
  alias DodoRouter.Routers

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
    params = prepare_params(params, socket.assigns.target_lookup)

    form =
      %Evaluation{}
      |> Evaluations.change_evaluation(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:selected_targets, params["candidate_target_values"] || [])
     |> sync_judge(params)}
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
    params =
      params
      |> prepare_params(socket.assigns.target_lookup)
      |> add_sources(socket.assigns.recording, socket.assigns.source_logs)

    if params["comparison_mode"] == "next_action" and
         Enum.any?(socket.assigns.source_logs, &Evaluations.next_action_blocker/1) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Next-action mode compares against the recorded response, and at least one source request has none on record. Use rubric mode for this set."
       )}
    else
      save_evaluation(socket, params)
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
  end

  @impl true
  def render(assigns) do
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
              id="judge-rubric"
              class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
            >
              <p class="text-xs font-semibold uppercase tracking-wider text-primary">Step 2</p>
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
              <p class="text-xs font-semibold uppercase tracking-wider text-primary">Step 3</p>
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
                :if={length(@source_logs) > 1}
                id="planned-runs-note"
                class="mt-2 text-xs text-base-content/55"
              >
                {length(@source_logs)} requests × {max(length(@selected_targets), 1)} models × {reps_value(
                  @form
                )} repetitions =
                <span class="font-semibold">
                  {length(@source_logs) * max(length(@selected_targets), 1) * reps_value(@form)}
                </span>
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
