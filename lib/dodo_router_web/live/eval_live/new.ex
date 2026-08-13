defmodule DodoRouterWeb.EvalLive.New do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs
  alias DodoRouter.Logs.Evaluation
  alias DodoRouter.Providers
  alias DodoRouter.Replays

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    log = Logs.get_log!(socket.assigns.current_user, id)
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
      prefill_evaluation(source, log)
      |> Evaluations.change_evaluation()
      |> to_form()

    selected_targets =
      case source do
        nil ->
          []

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

  defp key_label(target) do
    case target.provider_key.label do
      label when label in [nil, ""] -> "#{target.display_name} · Key"
      label -> "#{target.display_name} · #{label}"
    end
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

  defp prefill_evaluation(nil, log) do
    %Evaluation{name: "Evaluation of #{String.slice(log.request_id, 0, 8)}"}
  end

  defp prefill_evaluation(source, _log) do
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
    params = prepare_params(params, socket.assigns.target_lookup)

    case Evaluations.create_evaluation(socket.assigns.current_user, socket.assigns.log, params) do
      {:ok, evaluation} ->
        # Enqueue here, from the explicit save action: a run flag in the
        # destination URL would re-trigger a paid benchmark on refresh.
        Evaluations.enqueue(socket.assigns.current_user, evaluation)

        {:noreply,
         socket
         |> put_flash(:info, "Benchmark queued")
         |> push_navigate(to: ~p"/evals/#{evaluation.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

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
          <.link navigate={~p"/logs/#{@log.id}"} class="btn btn-ghost btn-square" id="eval-back-link">
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">
              New evaluation
            </p>
            <h1 class="text-3xl font-semibold tracking-tight">
              Turn this request into a quality test
            </h1>
            <p class="mt-1 text-sm text-base-content/55">
              The request and response are preserved as judge evidence.
            </p>
          </div>
        </div>

        <div id="eval-source" class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm">
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
                Each selected model will answer the source request.
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
