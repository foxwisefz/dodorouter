defmodule DodoRouterWeb.EvalLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.Evaluation
  alias DodoRouter.Recordings

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(DodoRouter.PubSub, "evaluation:#{id}")

    # Mount must stay side-effect free: benchmarks start only from explicit
    # actions, never from navigating (or refreshing, or reconnecting).
    case Evaluations.get_evaluation(socket.assigns.current_user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Evaluation not found")
         |> push_navigate(to: ~p"/evals")}

      evaluation ->
        {:ok,
         socket
         |> assign(:show_errored, MapSet.new())
         |> assign(:expanded_rankings, MapSet.new())
         |> assign(:selected_batch, nil)
         |> assign(:criteria_expanded, false)
         |> assign(:retrying?, false)
         |> assign(:retry_progress, nil)
         |> assign(:selected_series, nil)
         |> assign(:tradeoff_axis, :speed)
         |> load(evaluation)}
    end
  end

  @impl true
  def handle_event("run", params, socket) do
    {:noreply, start_benchmark(socket, parse_repetitions(params["repetitions"]))}
  end

  def handle_event("cancel", _params, socket) do
    case Evaluations.cancel_benchmark(socket.assigns.current_user, socket.assigns.evaluation) do
      :ok ->
        # The broadcast reloads the page state; the flash rides on it.
        {:noreply, socket}

      {:error, :not_running} ->
        {:noreply,
         socket
         |> assign(:running?, false)
         |> put_flash(:info, "Nothing is running — the benchmark already finished")}
    end
  end

  def handle_event("retry_failed", _params, socket) do
    user = socket.assigns.current_user
    evaluation = socket.assigns.evaluation
    retrying = retry_description(socket.assigns.retryable)

    # Returns as soon as the work is handed to a task. Running it inline
    # meant no render happened until every retried run finished, so the
    # button sat there looking broken for the length of the whole retry.
    case Evaluations.enqueue_retry(user, evaluation) do
      :ok ->
        total = socket.assigns.retryable.judge + socket.assigns.retryable.candidate

        {:noreply,
         socket
         |> assign(:running?, true)
         |> assign(:retrying?, true)
         |> assign(:retry_progress, %{done: 0, total: total})
         |> put_flash(:info, "Retrying: #{retrying}")}

      {:error, :already_running} ->
        {:noreply,
         socket |> assign(:running?, true) |> put_flash(:error, "A benchmark is already running")}
    end
  end

  def handle_event("toggle_errored", %{"batch" => batch_dom_id}, socket) do
    shown = socket.assigns.show_errored

    shown =
      if MapSet.member?(shown, batch_dom_id),
        do: MapSet.delete(shown, batch_dom_id),
        else: MapSet.put(shown, batch_dom_id)

    {:noreply, assign(socket, :show_errored, shown)}
  end

  def handle_event("select_batch", %{"batch" => dom_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_batch, dom_id)
     |> load(socket.assigns.evaluation)}
  end

  def handle_event("toggle_criteria", _params, socket) do
    {:noreply, assign(socket, :criteria_expanded, not socket.assigns.criteria_expanded)}
  end

  def handle_event("apply_verdict", %{"key" => key_id, "model" => model}, socket) do
    case Evaluations.apply_verdict(socket.assigns.current_user, socket.assigns.evaluation, %{
           "provider_key_id" => key_id,
           "model" => model
         }) do
      {:ok, _step, _event} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Routing updated — #{model} now serves this traffic. Revert from this page if it disappoints."
         )
         |> load(socket.assigns.evaluation)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, verdict_error(reason))}
    end
  end

  def handle_event("revert_verdict", %{"event" => event_id}, socket) do
    case Evaluations.revert_verdict(socket.assigns.current_user, event_id) do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Routing reverted to what it was before this benchmark.")
         |> load(socket.assigns.evaluation)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, verdict_error(reason))}
    end
  end

  def handle_event("toggle_ranking_sources", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded_rankings

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, :expanded_rankings, expanded)}
  end

  def handle_event("select_series", %{"series" => key}, socket) do
    selected = if socket.assigns.selected_series == key, do: nil, else: key
    {:noreply, assign(socket, :selected_series, selected)}
  end

  def handle_event("tradeoff_axis", %{"axis" => axis}, socket) when axis in ~w(speed cost) do
    {:noreply, assign(socket, :tradeoff_axis, String.to_existing_atom(axis))}
  end

  @impl true
  def handle_info({:benchmark_finished, {:ok, _results}}, socket) do
    evaluation =
      Evaluations.get_evaluation!(socket.assigns.current_user, socket.assigns.evaluation.id)

    message = if socket.assigns[:retrying?], do: "Retry finished", else: "Benchmark completed"

    {:noreply,
     socket
     |> assign(:retrying?, false)
     |> assign(:retry_progress, nil)
     |> load(evaluation)
     |> put_flash(:info, message)}
  end

  # Lets a retry report progress the only way it can be counted: one
  # broadcast per run finished, against the number being retried.
  def handle_info({:retry_started, total}, socket) do
    {:noreply,
     socket
     |> assign(:retrying?, true)
     |> assign(:running?, true)
     |> assign(:retry_progress, %{done: 0, total: total})}
  end

  def handle_info({:benchmark_progress, _result}, socket) do
    evaluation =
      Evaluations.get_evaluation!(socket.assigns.current_user, socket.assigns.evaluation.id)

    {:noreply, socket |> advance_retry() |> load(evaluation)}
  end

  def handle_info({:benchmark_finished, :cancelled}, socket) do
    evaluation =
      Evaluations.get_evaluation!(socket.assigns.current_user, socket.assigns.evaluation.id)

    {:noreply,
     socket
     |> assign(:running?, false)
     |> assign(:retrying?, false)
     |> assign(:retry_progress, nil)
     |> load(evaluation)
     |> put_flash(:info, "Benchmark cancelled — stored answers stay and can be re-judged")}
  end

  def handle_info({:benchmark_finished, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> put_flash(:error, "Benchmark stopped: " <> Evaluations.proxy_error_message(reason))}
  end

  # nil means "keep the evaluation's current repetitions"; the input's
  # min/max mirror the changeset bounds, and anything unparseable falls back
  # to no override rather than an error nobody typed on purpose.
  defp parse_repetitions(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_repetitions(_), do: nil

  defp start_benchmark(socket, repetitions) do
    user = socket.assigns.current_user
    evaluation = socket.assigns.evaluation

    case Evaluations.enqueue(user, evaluation, repetitions: repetitions) do
      :ok ->
        socket
        |> assign(:running?, true)
        |> assign(:evaluation, Evaluations.get_evaluation!(user, evaluation.id))

      {:error, :already_running} ->
        # Silently flipping to "running" made a refused click look like an
        # accepted one — the button changed and nothing ever happened.
        socket
        |> assign(:running?, true)
        |> put_flash(:info, "A benchmark for this evaluation is already running")

      {:error, {:judge_key_unusable, blocker}} ->
        put_flash(
          socket,
          :error,
          "Not starting: the judge's key #{blocker.label} is #{humanize_status(blocker.status)}. " <>
            "Every answer would be generated and paid for, then thrown away unscored. " <>
            "Pick another judge key first."
        )

      {:error, {:too_many_runs, planned, max}} ->
        put_flash(
          socket,
          :error,
          "Not starting: #{planned} runs planned (logs × candidates × repetitions); the cap is #{max}."
        )

      {:error, {:candidates_unusable, blockers}} ->
        named =
          Enum.map_join(blockers, ", ", fn b ->
            "#{b[:label] || "a removed key"} (#{humanize_status(b.status)})"
          end)

        put_flash(
          socket,
          :error,
          "Not starting: every candidate is blocked — #{named}. Nothing could produce an " <>
            "answer, so running would only spend the judge's quota."
        )

      {:error, %Ecto.Changeset{}} ->
        put_flash(socket, :error, "Repetitions must be between 1 and 10")

      {:error, reason} ->
        put_flash(
          socket,
          :error,
          "Could not start benchmark: " <> Evaluations.proxy_error_message(reason)
        )
    end
  end

  # {done, total} for the bar, or nil when there is nothing honest to count.
  defp progress_counts(true, %{total: total} = progress, _summary, _evaluation) when total > 0,
    do: {progress.done, total}

  defp progress_counts(true, _progress, _summary, _evaluation), do: nil

  defp progress_counts(_retrying?, _progress, summary, evaluation),
    do: {min(summary.runs, planned_runs(evaluation)), planned_runs(evaluation)}

  # A retry re-runs rows that already exist, so counting against the plan
  # reads "18 of 18" from the first second. The denominator is the set being
  # retried, counted one broadcast per finished run.
  defp progress_line(true, %{total: total} = progress, _summary, _evaluation) when total > 0 do
    "#{progress.done} of #{total} retried. Scores and rankings update as each result lands."
  end

  defp progress_line(true, _progress, _summary, _evaluation) do
    "Repeating only what failed. Scores and rankings update as each result lands."
  end

  defp progress_line(_retrying?, _progress, summary, evaluation) do
    "#{min(summary.runs, planned_runs(evaluation))} of #{planned_runs(evaluation)} candidate runs finished. " <>
      "Scores and rankings update as each result lands."
  end

  defp advance_retry(%{assigns: %{retry_progress: %{done: done, total: total}}} = socket) do
    assign(socket, :retry_progress, %{done: min(done + 1, total), total: total})
  end

  defp advance_retry(socket), do: socket

  # A stored "running" is only true while a process is actually running. A
  # crash, a restart, or a status write that never landed leaves the row
  # saying running forever — and a page that spins forever is worse than one
  # that admits the benchmark stopped without finishing.
  defp display_status(%{benchmark_status: "running"}, false), do: "interrupted"
  defp display_status(%{benchmark_status: status}, _running?), do: status

  # Keyed by the pair, not the model: the same model can appear twice under
  # different keys, and only one of them may be the problem.
  defp candidate_issues(%{candidates: blocked}) do
    Map.new(blocked, fn issue -> {{issue.key_id, issue.model}, issue.status} end)
  end

  defp candidate_issue(issues, target) do
    Map.get(issues, {target["provider_key_id"], target["model"]})
  end

  defp candidate_keys(user) do
    user |> DodoRouter.Providers.list_provider_keys() |> Map.new(&{&1.id, &1})
  end

  # Superseded attempts, grouped under the run that replaced them. Loaded
  # once per render rather than per run, since a batch can hold dozens.
  defp previous_attempts_by_run(evaluation) do
    evaluation.runs
    |> Enum.filter(& &1.superseded_at)
    |> Enum.group_by(& &1.superseded_by_id)
    |> Map.new(fn {run_id, attempts} ->
      {run_id, Enum.sort_by(attempts, & &1.superseded_at, {:desc, DateTime})}
    end)
  end

  # The target stores the key by id, so the panel resolves it and labels it
  # the one shared way rather than inventing a fourth format.
  defp candidate_key_label(target, keys) do
    case Map.get(keys, target["provider_key_id"]) do
      nil -> target["provider_name"] || target["provider"] || "key no longer configured"
      key -> DodoRouterWeb.ProviderComponents.provider_key_option_label(key)
    end
  end

  # A retired model is not a key problem, so it does not borrow the key's
  # wording: the key is fine, the model is gone, and duplicating the
  # evaluation to pick a current one is the way out.
  defp candidate_blocker_line(%{status: "retired"} = blocked) do
    "Candidate #{blocked.model} is no longer offered by #{blocked.label} — the provider " <>
      "retired it. Duplicate this evaluation and pick a current model."
  end

  defp candidate_blocker_line(blocked) do
    "Candidate #{blocked.model} uses #{blocked.label}, which is " <>
      "#{humanize_status(blocked.status)} — those runs will fail."
  end

  defp humanize_status("retired"), do: "retired"
  defp humanize_status("quota_exceeded"), do: "out of quota"
  defp humanize_status("invalid"), do: "not authenticating"
  defp humanize_status(other), do: String.replace(other, "_", " ")

  defp load(socket, evaluation) do
    batches = group_batches(evaluation)
    selected = selected_batch(socket.assigns[:selected_batch], batches)
    group = Enum.find(batches, &(&1.dom_id == selected))
    batch_runs = if group, do: Evaluations.live_runs(group.runs), else: []
    rankings = Evaluations.rankings(batch_runs)

    recording =
      evaluation.recording_id &&
        Recordings.get_recording(socket.assigns.current_user, evaluation.recording_id)

    socket
    |> assign(:page_title, evaluation.name)
    |> assign(:evaluation, evaluation)
    |> assign(:source_count, length(Evaluation.source_log_ids(evaluation)))
    |> assign(:recording, recording)
    |> assign(:projection, projection(recording, rankings))
    |> assign(:applied_changes, Evaluations.list_applied_changes(evaluation))
    |> assign(:batches, batches)
    |> assign(:selected_batch, selected)
    |> assign(:selected_group, group)
    |> assign(:summary, Evaluations.summary(batch_runs))
    |> assign(:rankings, rankings)
    |> assign(:chart_series, chart_series(batch_runs, rankings))
    |> assign(:rubric_feedback, Evaluations.rubric_feedback(batch_runs))
    |> assign(:retryable, Evaluations.retryable_counts(evaluation))
    |> assign(:shared_key_label, shared_key_label(evaluation))
    |> assign(:preflight, Evaluations.preflight(socket.assigns.current_user, evaluation))
    |> assign(
      :failure_digest,
      failure_digest(evaluation, batch_runs, Evaluations.benchmark_running?(evaluation))
    )
    |> assign(:candidate_keys, candidate_keys(socket.assigns.current_user))
    |> assign(
      :candidate_issues,
      candidate_issues(Evaluations.preflight(socket.assigns.current_user, evaluation))
    )
    |> assign(:previous_attempts, previous_attempts_by_run(evaluation))
    |> assign(:running?, Evaluations.benchmark_running?(evaluation))
  end

  # A nil pick means "follow the latest": a reload mid-benchmark keeps
  # showing the batch that is filling up. An explicit pick survives reloads
  # and is dropped only when the batch itself no longer exists.
  defp selected_batch(picked, batches) do
    cond do
      batches == [] -> nil
      picked && Enum.any?(batches, &(&1.dom_id == picked)) -> picked
      true -> hd(batches).dom_id
    end
  end

  # Judging and generating through one account is how a benchmark rate
  # limits itself: every repetition of every target spends the same quota
  # twice. Knowable before the run, so it is said before the run.
  defp shared_key_label(evaluation) do
    shared? =
      Enum.any?(evaluation.candidate_targets, fn target ->
        target["provider_key_id"] == evaluation.judge_provider_key_id
      end)

    if shared? and evaluation.judge_provider_key, do: evaluation.judge_provider_key.label
  end

  # Six lines is roughly where the rubric stops being a caption and starts
  # being a document. Measured in lines, not characters, because that is
  # what actually drives the panel's height.
  @criteria_clamp_chars 400

  defp long_criteria?(%{criteria: criteria}) when is_binary(criteria) do
    String.length(criteria) > @criteria_clamp_chars or
      length(String.split(criteria, "\n")) > 6
  end

  defp long_criteria?(_evaluation), do: false

  # Eighteen failing rows are four facts wearing eighteen costumes. Group by
  # the provider and the reason, because that is the shape of the decision
  # they lead to: top up this account, wait out that rate limit.
  defp failure_digest(evaluation, runs, running?) do
    failed =
      runs
      |> Enum.filter(&(&1.status == "failed"))
      |> Enum.group_by(fn run ->
        {failing_provider(run), failure_kind(run.error), run.failure_stage}
      end)
      |> Enum.map(fn {{provider, kind, stage}, grouped} ->
        %{label: provider, detail: kind, stage: stage, count: length(grouped)}
      end)

    (failed ++ interrupted_group(runs, running?) ++ never_started_group(evaluation, runs))
    |> Enum.sort_by(& &1.count, :desc)
  end

  # Rows the benchmark created but never resolved. Only leftovers once
  # nothing is executing — while a benchmark runs they are simply in flight.
  defp interrupted_group(runs, false) do
    case Enum.count(runs, &(&1.status in ["pending", "running"])) do
      0 ->
        []

      count ->
        [
          %{
            label: "Interrupted",
            detail: "the benchmark stopped before these finished",
            stage: nil,
            count: count
          }
        ]
    end
  end

  defp interrupted_group(_runs, _running?), do: []

  # The population with no rows at all. A candidate the benchmark never
  # reached has nothing in the run list, nothing in the rankings and nothing
  # in the failure counts — it is invisible unless the plan is compared with
  # what was actually recorded.
  defp never_started_group(evaluation, runs) do
    recorded =
      runs
      |> Enum.group_by(&{&1.candidate_provider, &1.candidate_model})
      |> Map.new(fn {key, rows} -> {key, length(rows)} end)

    missing =
      evaluation.candidate_targets
      |> Enum.map(fn target ->
        key = {target["provider"], target["model"]}
        {target["model"], evaluation.repetitions - Map.get(recorded, key, 0)}
      end)
      |> Enum.filter(fn {_model, shortfall} -> shortfall > 0 end)

    case missing do
      [] ->
        []

      _ ->
        [
          %{
            label: "Never started",
            detail: Enum.map_join(missing, ", ", fn {model, _} -> model end),
            stage: nil,
            count: Enum.sum(Enum.map(missing, fn {_, shortfall} -> shortfall end))
          }
        ]
    end
  end

  # A judge failure belongs to whoever served the judge, not to the model
  # being scored — filing it under the candidate is what made six healthy
  # answers look like six broken models.
  defp failing_provider(%{failure_stage: "judge"} = run) do
    run.judge_provider_key_label || "judge"
  end

  defp failing_provider(run), do: run.candidate_provider || "unknown"

  @failure_kinds [
    {"out of quota", ~w(quota usage\ limit access_terminated billing credits)},
    {"rate limited", ["rate limit", "rate_limited"]},
    {"timed out", ["timed out", "timeout"]},
    {"authentication refused", ["auth error", "auth_error", "unauthorized", "403"]}
  ]

  defp failure_kind(nil), do: "failed"

  defp failure_kind(error) do
    down = String.downcase(error)

    Enum.find_value(@failure_kinds, "failed", fn {label, markers} ->
      if Enum.any?(markers, &String.contains?(down, &1)), do: label
    end)
  end

  defp run_has_detail?(run) do
    map_size(run.criterion_scores) > 0 or run.issues != [] or
      run.candidate_output not in [nil, ""] or not is_nil(run.reasoning)
  end

  # Name what is inside, so expanding is a decision rather than a gamble.
  defp run_detail_label(run) do
    [
      run.issues != [] &&
        "#{length(run.issues)} #{if length(run.issues) == 1, do: "issue", else: "issues"}",
      map_size(run.criterion_scores) > 0 && "criterion scores",
      run.candidate_output not in [nil, ""] && "the answer",
      run.reasoning && "judge reasoning"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp any_scored?(chart_series) do
    Enum.any?(chart_series, fn series -> scored_points(series) != [] end)
  end

  defp retry_description(%{judge: judge, candidate: candidate}) do
    parts =
      [
        judge > 0 && "re-judge #{judge}",
        candidate > 0 && "re-run #{candidate}"
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join(parts, ", ")
  end

  # One entry per ranked model: scored runs positioned by repetition slot
  # (so an errored repetition leaves a visible gap in the line). Errored
  # runs stay off the chart — they surface as legend counts only.
  #
  # Repetition slots only work when a series has each repetition once. A
  # legacy pool (nil batch_id) can mix several executions, so repetition
  # numbers collide — those series fall back to chronological slots to
  # keep every run at its own x position.
  defp chart_series(batch_runs, rankings) do
    positioned =
      Enum.map(rankings, fn ranking ->
        runs =
          batch_runs
          |> Enum.filter(
            &(&1.candidate_provider == ranking.provider and
                &1.candidate_model == ranking.model and
                &1.variant_name == ranking.variant)
          )
          |> Enum.sort_by(&{&1.repetition, &1.inserted_at, &1.id})

        repetitions = Enum.map(runs, & &1.repetition)

        unique_repetitions? =
          Enum.all?(repetitions, &is_integer/1) and
            length(Enum.uniq(repetitions)) == length(repetitions)

        points =
          runs
          |> Enum.with_index()
          |> Enum.map(fn {run, idx} ->
            %{
              run: run,
              slot: if(unique_repetitions?, do: run.repetition - 1, else: idx),
              scored?: run.status == "completed" and is_integer(run.score)
            }
          end)

        {ranking, points}
      end)

    slots =
      positioned
      |> Enum.flat_map(fn {_ranking, points} -> Enum.map(points, & &1.slot) end)
      |> Enum.max(fn -> 1 end)
      |> Kernel.+(1)
      |> max(2)

    positioned
    |> Enum.with_index()
    |> Enum.map(fn {{ranking, points}, index} ->
      %{
        key: "#{ranking.provider}|#{ranking.model}|#{ranking.variant}",
        provider: ranking.provider,
        model: ranking.model,
        variant: ranking.variant,
        color: chart_color(index),
        points: Enum.map(points, &Map.put(&1, :x, chart_x(&1.slot, slots)))
      }
    end)
  end

  defp scored_points(series), do: Enum.filter(series.points, & &1.scored?)
  defp errored_points(series), do: Enum.reject(series.points, & &1.scored?)

  defp polyline_points(series) do
    series
    |> scored_points()
    |> Enum.map_join(" ", fn point -> "#{point.x},#{chart_y(point.run.score)}" end)
  end

  defp series_opacity(nil, _key), do: "1"
  defp series_opacity(key, key), do: "1"
  defp series_opacity(_selected, _key), do: "0.15"

  # One section per benchmark execution, latest first. Runs recorded before
  # batching (nil batch_id) collapse into a single "legacy" group.
  defp group_batches(evaluation) do
    {latest, earlier} =
      evaluation.runs
      |> Enum.group_by(& &1.batch_id)
      |> Enum.map(fn {batch_id, runs} ->
        %{
          id: batch_id,
          dom_id: batch_id || "legacy",
          latest?: batch_id != nil and batch_id == evaluation.last_batch_id,
          started_at: runs |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime),
          runs: Enum.sort_by(runs, &{&1.candidate_provider, &1.candidate_model, &1.repetition}),
          errored: Enum.count(runs, &(&1.status == "failed"))
        }
      end)
      |> Enum.split_with(& &1.latest?)

    latest ++ Enum.sort_by(earlier, & &1.started_at, {:desc, DateTime})
  end

  # Errors show by default. They were hidden behind a toggle on the theory
  # that a batch is mostly successes with a few duds; a batch where 16 of 18
  # failed is the opposite, and the page opened on two scored runs with no
  # sign of what happened to the rest.
  defp visible_runs(batch, hidden_errors) do
    if MapSet.member?(hidden_errors, batch.dom_id),
      do: Enum.reject(batch.runs, &(&1.status == "failed")),
      else: batch.runs
  end

  defp any_succeeded?(batch), do: Enum.any?(batch.runs, &(&1.status != "failed"))

  defp ranking_key(ranking), do: "#{ranking.provider}|#{ranking.model}|#{ranking.variant}"

  # Model ids can carry characters a DOM id cannot; the key stays readable
  # for the event, the id just has to be stable and unique.
  defp ranking_dom_id(ranking),
    do: ranking |> ranking_key() |> :erlang.phash2() |> Integer.to_string()

  # The weakest source's average — or the fact that it never scored at all,
  # which is the louder signal.
  defp worst_source_label(%{per_source: [worst | _]}) do
    worst.average || "unscored"
  end

  # The candidate target that produced this ranking row — carries the
  # provider_key_id an apply needs, which the ranking itself does not.
  defp apply_target(evaluation, ranking) do
    Enum.find(evaluation.candidate_targets || [], fn target ->
      target["model"] == ranking.model and target["provider"] == ranking.provider
    end)
  end

  defp verdict_error(:no_incumbent),
    do:
      "The source request doesn't name which routing step served it, so there is nothing to safely update. Edit the routing step directly."

  defp verdict_error(:no_matching_step),
    do:
      "No routing step currently serves this benchmark's incumbent — routing may have been edited since. Edit the step directly."

  defp verdict_error(:ambiguous_step),
    do: "Several routing steps match the incumbent — edit the one you mean directly."

  defp verdict_error(:already_serving), do: "That model already serves this traffic."

  defp verdict_error(:unknown_key),
    do: "That candidate's provider key is no longer on your account."

  defp verdict_error(:variant_not_applicable),
    do:
      "A prompt variant can't be applied as routing — the system prompt lives in your product's code, not in the router."

  defp verdict_error(:not_found), do: "That routing change no longer exists."
  defp verdict_error(:already_reverted), do: "That routing change was already reverted."

  defp verdict_error(:step_deleted),
    do: "The routing step this change touched has been deleted — nothing to revert."

  defp verdict_error(%Ecto.Changeset{}),
    do: "The routing step update was invalid — edit the step directly."

  # Only a recording gives the projection its denominator: a hand-picked
  # log set has no traffic rate to scale by.
  defp projection(nil, _rankings), do: nil
  defp projection(_recording, []), do: nil

  defp projection(recording, rankings) do
    stats = Recordings.recording_stats(recording)

    case Evaluations.savings_projection(rankings, recording, stats) do
      {:ok, projection} -> projection
      {:error, reason} -> reason
    end
  end

  defp window_label(seconds) when seconds >= 3600,
    do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp window_label(seconds), do: "#{div(seconds, 60)}m"

  defp savings_class(nil), do: "text-base-content/40"

  defp savings_class(savings) do
    if Decimal.negative?(savings), do: "text-error", else: "text-success"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl space-y-7">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex items-start gap-3">
            <.link navigate={~p"/evals"} id="eval-index-link" class="btn btn-ghost btn-square">
              <.icon name="hero-arrow-left" class="size-5" />
            </.link>
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">Evaluation</p>
              <h1 class="text-3xl font-semibold tracking-tight">{@evaluation.name}</h1>
              <div class="mt-2 flex flex-wrap gap-2 text-xs text-base-content/50">
                <span :if={@source_count == 1} class="rounded-full bg-base-200 px-2.5 py-1">
                  Source: {@evaluation.request_log.final_provider} / {@evaluation.request_log.final_model}
                </span>
                <span
                  :if={@source_count > 1}
                  id="eval-source-count"
                  class="rounded-full bg-base-200 px-2.5 py-1"
                >
                  Sources: {@source_count} requests — rankings aggregate across all of them
                </span>
                <.link
                  :if={@recording}
                  id="eval-recording-link"
                  navigate={~p"/routers/#{@recording.router_id}/recordings/#{@recording.id}"}
                  class="rounded-full bg-base-200 px-2.5 py-1 hover:text-primary"
                >
                  From recording: {@recording.name || "Recording"}
                </.link>
                <span class="rounded-full bg-primary/10 px-2.5 py-1 text-primary">
                  Judge: {@evaluation.judge_model}
                </span>
                <span
                  :if={@evaluation.benchmark_status not in [nil, "draft", "completed"]}
                  id="eval-status"
                  class={[
                    "rounded-full px-2.5 py-1",
                    display_status(@evaluation, @running?) in ["failed", "interrupted"] &&
                      "bg-error/10 text-error",
                    display_status(@evaluation, @running?) == "partial" &&
                      "bg-warning/10 text-warning",
                    display_status(@evaluation, @running?) == "running" &&
                      "bg-primary/10 text-primary"
                  ]}
                >
                  Last run: {display_status(@evaluation, @running?)}
                </span>
              </div>
            </div>
          </div>
          <%!-- Wraps and never shrinks: a long "Retry failed (re-judge 4,
          re-run 12)" pushed "Run again" off the right edge of the page. --%>
          <div class="flex shrink-0 flex-wrap items-center justify-end gap-2">
            <.link
              id="duplicate-eval-button"
              navigate={~p"/logs/#{@evaluation.request_log_id}/evals/new?from=#{@evaluation.id}"}
              class="btn btn-ghost gap-2"
              title="Start a new evaluation prefilled from this one"
            >
              <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
            </.link>
            <button
              :if={@retryable.judge + @retryable.candidate > 0}
              id="retry-failed-button"
              phx-click="retry_failed"
              disabled={@running?}
              class="btn btn-outline gap-2"
              title={"Repeats only what failed — #{retry_description(@retryable)}. Answers already paid for are reused."}
            >
              <.icon
                name={if @running?, do: "hero-arrow-path", else: "hero-arrow-uturn-left"}
                class={"size-4 " <> if(@running?, do: "animate-spin", else: "")}
              />
              {if @running?,
                do: "Retrying…",
                else: "Retry #{@retryable.judge + @retryable.candidate} failed"}
            </button>
            <button
              :if={@running?}
              id="cancel-eval-button"
              phx-click="cancel"
              data-confirm="Stop this benchmark? Unfinished runs are marked cancelled; answers already generated stay stored and can be re-judged."
              class="btn btn-outline btn-error gap-2"
            >
              <.icon name="hero-stop" class="size-4" /> Cancel
            </button>
            <form id="run-eval-form" phx-submit="run" class="flex items-center gap-2">
              <label
                for="run-repetitions"
                class="text-sm text-base-content/60"
                title="Repetitions per candidate for this run — persists as the evaluation's setting"
              >
                × runs
              </label>
              <input
                id="run-repetitions"
                name="repetitions"
                type="number"
                min="1"
                max="10"
                value={@evaluation.repetitions}
                disabled={@running?}
                class="input input-bordered input-sm w-16 text-center"
              />
              <button
                id="run-eval-button"
                type="submit"
                disabled={@running?}
                class="btn btn-primary gap-2"
              >
                <.icon name="hero-play" class="size-4" /> {if @running?,
                  do: "Benchmark running…",
                  else: "Run again"}
              </button>
            </form>
          </div>
        </div>

        <%!-- Stays up for the whole retry: every progress broadcast reloads
        and recomputes `running?`, and a panel that blinks out between runs
        is worse than no panel. --%>
        <div
          :if={@running? or @retrying?}
          id="eval-progress"
          class="rounded-2xl border border-primary/20 bg-primary/5 p-5"
        >
          <div class="flex items-center gap-3">
            <.icon name="hero-arrow-path" class="size-5 animate-spin text-primary" />
            <div>
              <div class="font-semibold">
                {if @retrying?, do: "Retrying failed runs", else: "Live benchmark"}
              </div>
              <%!-- A retry re-runs rows that already exist, so counting runs
              against the plan would read "18 of 18" from the first second. --%>
              <div class="text-sm text-base-content/50">
                {progress_line(@retrying?, @retry_progress, @summary, @evaluation)}
              </div>
            </div>
          </div>
          <progress
            :if={progress_counts(@retrying?, @retry_progress, @summary, @evaluation)}
            class="progress progress-primary mt-4 w-full"
            value={elem(progress_counts(@retrying?, @retry_progress, @summary, @evaluation), 0)}
            max={elem(progress_counts(@retrying?, @retry_progress, @summary, @evaluation), 1)}
          >
          </progress>
          <%!-- Indeterminate only when there is genuinely nothing to count:
          a page reloaded mid-retry has no broadcast history to add up. --%>
          <progress
            :if={is_nil(progress_counts(@retrying?, @retry_progress, @summary, @evaluation))}
            class="progress progress-primary mt-4 w-full"
          >
          </progress>
        </div>

        <div
          :if={@shared_key_label}
          id="shared-key-warning"
          class="flex items-start gap-3 rounded-2xl border border-warning/30 bg-warning/5 p-4 text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-warning" />
          <p class="text-base-content/70">
            The judge and at least one candidate both use
            <span class="font-medium">{@shared_key_label}</span>
            — every repetition spends that account's quota twice, which is the usual
            cause of a batch that rate-limits itself. Consider a separate key for the judge.
          </p>
        </div>

        <%!-- Health the proxy already recorded, said before the run rather
        than discovered one failed call at a time. --%>
        <div
          :if={@preflight.judge || @preflight.candidates != []}
          id="key-preflight"
          class={[
            "rounded-2xl border p-4 text-sm",
            @preflight.judge && "border-error/30 bg-error/5",
            !@preflight.judge && "border-warning/30 bg-warning/5"
          ]}
        >
          <div class="flex items-start gap-3">
            <.icon
              name="hero-exclamation-triangle"
              class={"size-5 shrink-0 " <> if(@preflight.judge, do: "text-error", else: "text-warning")}
            />
            <div class="space-y-1">
              <p :if={@preflight.judge} class="font-medium text-error">
                The judge's key {@preflight.judge.label} is {humanize_status(@preflight.judge.status)} — this benchmark will not start.
              </p>
              <p :for={blocked <- @preflight.candidates} class="text-base-content/70">
                {candidate_blocker_line(blocked)}
              </p>
              <p class="text-xs text-base-content/50">
                Recorded from earlier traffic. Fix the key, or
                <.link navigate={~p"/providers"} class="text-primary hover:underline">
                  add another
                </.link>
                and duplicate this evaluation.
              </p>
            </div>
          </div>
        </div>

        <%!-- The failure list, said once per cause instead of once per run. --%>
        <div
          :if={@failure_digest != []}
          id="failure-digest"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm"
        >
          <h2 class="font-semibold">What happened to these runs</h2>
          <p class="text-sm text-base-content/45">
            Every planned run, grouped by outcome — including the ones that never started.
          </p>
          <ul class="mt-3 space-y-2 text-sm">
            <li :for={group <- @failure_digest} class="flex items-baseline gap-2">
              <span class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold">
                {group.count}
              </span>
              <span class="font-medium">{group.label}</span>
              <span class="text-base-content/60">
                {group.detail}{if group.stage == "judge", do: " (as the judge)", else: ""}
              </span>
            </li>
          </ul>
        </div>

        <%!-- What this evaluation is set up to measure. The rankings table
        only lists models that produced runs, so an evaluation that never
        ran — or died halfway — said nothing about its own configuration. --%>
        <div
          id="eval-candidates"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h2 class="font-semibold">Candidates</h2>
            <span class="text-sm text-base-content/45">
              {length(@evaluation.candidate_targets)} × {@evaluation.repetitions} repetitions = {planned_runs(
                @evaluation
              )} runs
            </span>
          </div>
          <ul class="mt-3 grid gap-2 sm:grid-cols-2">
            <li
              :for={target <- @evaluation.candidate_targets}
              class="flex items-baseline justify-between gap-3 rounded-xl bg-base-200/40 px-3 py-2 text-sm"
            >
              <span class="flex items-baseline gap-2">
                <span class="font-mono text-xs">{target["model"]}</span>
                <%!-- The banner states the problem once; the list is where
                the eye goes to answer "which of these six is it". --%>
                <span
                  :if={issue = candidate_issue(@candidate_issues, target)}
                  class="rounded-full bg-warning/15 px-2 py-0.5 text-[11px] font-medium text-warning"
                >
                  {humanize_status(issue)}
                </span>
              </span>
              <span class="text-xs text-base-content/50">
                {candidate_key_label(target, @candidate_keys)}
              </span>
            </li>
          </ul>
        </div>

        <%!-- The page has one results view, scoped by the batch picked here.
        "Latest batch" used to appear twice — once as silent scope for the
        stats and charts, once as a run-history group — and read as two
        sections showing the same runs. --%>
        <div :if={@batches != []} id="batch-selector" class="space-y-2">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h2 class="font-semibold">Results by batch</h2>
            <p class="text-sm text-base-content/45">
              Stats, charts, rankings and runs below all reflect the selected batch.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              :for={batch <- @batches}
              id={"batch-#{batch.dom_id}"}
              type="button"
              phx-click="select_batch"
              phx-value-batch={batch.dom_id}
              class={[
                "flex items-baseline gap-2 rounded-xl border px-3.5 py-2 text-sm transition",
                batch.dom_id == assigns[:selected_batch] &&
                  "border-primary/40 bg-primary/10 font-semibold",
                batch.dom_id != assigns[:selected_batch] &&
                  "border-base-300/60 text-base-content/60 hover:bg-base-200"
              ]}
            >
              <span
                :if={batch.latest?}
                class="rounded-full bg-primary/15 px-2 py-0.5 text-xs font-semibold text-primary"
              >
                Latest
              </span>
              <span>{Calendar.strftime(batch.started_at, "%b %-d, %H:%M UTC")}</span>
              <span class="text-xs text-base-content/45">
                {length(batch.runs)} runs
              </span>
              <span :if={batch.errored > 0} class="text-xs text-error/70">
                · {batch.errored} errored
              </span>
            </button>
          </div>
        </div>

        <div id="eval-summary" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat
            label="Batch runs"
            value={to_string(@summary.runs)}
            detail={"#{@summary.completed} successful"}
          />
          <.stat
            label="Average quality"
            value={score(@summary.average)}
            detail={"Best #{@summary.best || "—"}"}
          />
          <.stat
            label="Average time"
            value={duration(@summary.avg_latency)}
            detail={batch_cost_detail(@summary)}
          />
          <.stat
            label="Errored runs"
            value={to_string(@summary.failed)}
            detail={"out of #{@summary.runs} batch runs"}
          />
        </div>

        <%!-- items-start: grid items stretch by default, so a long rubric
        set the chart's height and left the plot floating in whitespace. --%>
        <div id="eval-panels" class="grid items-start gap-6 lg:grid-cols-[1.4fr_1fr]">
          <section
            id="score-trend"
            class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
          >
            <div class="mb-6 flex items-center justify-between">
              <div>
                <h2 class="font-semibold">Score consistency</h2>
                <p class="text-sm text-base-content/45">
                  Judge scores per repetition in the selected batch
                </p>
              </div>
              <span :if={any_scored?(@chart_series)} class="text-xs text-base-content/40">0–100</span>
            </div>
            <%!-- Axes with no data are a chart pretending to be one. When
            nothing scored, say so — that IS the finding. --%>
            <div
              :if={not any_scored?(@chart_series)}
              class="rounded-xl border border-dashed border-base-300 px-6 py-10 text-center text-sm text-base-content/45"
            >
              No run has been scored in this batch, so there is nothing to plot yet.
              <span :if={@retryable.judge > 0} class="mt-1 block text-base-content/60">
                {@retryable.judge} of them already have an answer — retry to score it.
              </span>
            </div>
            <div
              :if={any_scored?(@chart_series)}
              id="quality-consistency-chart"
              class="overflow-x-auto"
            >
              <svg
                viewBox="0 0 900 280"
                class="min-w-[760px] w-full"
                role="img"
                aria-label="Quality scores by model and repetition"
              >
                <line x1="55" y1="20" x2="55" y2="240" stroke="currentColor" class="text-base-300" />
                <line x1="55" y1="240" x2="880" y2="240" stroke="currentColor" class="text-base-300" />
                <g
                  :for={{series, index} <- Enum.with_index(@chart_series)}
                  id={"chart-series-#{index}"}
                  class="series cursor-pointer"
                  opacity={series_opacity(@selected_series, series.key)}
                  phx-click="select_series"
                  phx-value-series={series.key}
                >
                  <polyline
                    :if={scored_points(series) != []}
                    fill="none"
                    stroke={series.color}
                    stroke-width="3"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    points={polyline_points(series)}
                  />
                  <circle
                    :for={point <- scored_points(series)}
                    cx={point.x}
                    cy={chart_y(point.run.score)}
                    r="5"
                    fill={series.color}
                  >
                    <title>{series.model} · run {point.run.repetition}: {point.run.score}</title>
                  </circle>
                </g>
                <text
                  :for={tick <- [0, 25, 50, 75, 100]}
                  x="18"
                  y={chart_y(tick) + 4}
                  class="fill-base-content/40 text-[11px]"
                >
                  {tick}
                </text>
              </svg>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <button
                  :for={{series, index} <- Enum.with_index(@chart_series)}
                  id={"chart-legend-#{index}"}
                  type="button"
                  phx-click="select_series"
                  phx-value-series={series.key}
                  class={[
                    "flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs transition",
                    @selected_series == series.key && "border-primary/40 bg-primary/10",
                    @selected_series != series.key && "border-transparent hover:bg-base-200"
                  ]}
                >
                  <i class="size-2.5 rounded-full" style={"background: #{series.color}"}></i>
                  <span>{series.provider} / {series.model}</span>
                  <span class="text-base-content/45">{length(scored_points(series))} scored</span>
                  <span
                    :if={errored_points(series) != []}
                    id={"chart-legend-errored-#{index}"}
                    class={[
                      "text-error/70",
                      @selected_series == series.key && "font-semibold text-error"
                    ]}
                  >
                    · {length(errored_points(series))} errored
                  </span>
                </button>
              </div>
              <div :if={@rankings == []} class="py-10 text-center text-sm text-base-content/40">
                Run the benchmark to compare model consistency.
              </div>
            </div>
          </section>

          <section class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm">
            <h2 class="font-semibold">Success criteria</h2>
            <p
              id="criteria-body"
              class={[
                "mt-3 whitespace-pre-wrap text-sm leading-6 text-base-content/70",
                @criteria_expanded && "max-h-[32rem] overflow-y-auto",
                not @criteria_expanded && long_criteria?(@evaluation) && "line-clamp-6"
              ]}
            >
              {@evaluation.criteria}
            </p>
            <button
              :if={long_criteria?(@evaluation)}
              id="toggle-criteria"
              type="button"
              phx-click="toggle_criteria"
              class="mt-2 text-sm font-medium text-primary hover:underline"
            >
              {if @criteria_expanded, do: "Show less", else: "Show full rubric"}
            </button>
            <div
              :if={@rubric_feedback.flagged > 0}
              id="rubric-feedback"
              class="mt-4 rounded-xl bg-warning/10 p-4 text-sm ring-1 ring-warning/20"
            >
              <div class="flex items-center gap-2 font-semibold text-warning">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                The judge flagged rubric gaps in {@rubric_feedback.flagged} of {@rubric_feedback.scored} scored runs
              </div>
              <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
                <li :for={gap <- Enum.take(@rubric_feedback.gaps, 5)}>{gap}</li>
              </ul>
              <p class="mt-2 text-xs text-base-content/50">
                Consider tightening the criteria or adding examples, then duplicate this evaluation.
              </p>
            </div>
            <.link
              navigate={~p"/logs/#{@evaluation.request_log.id}"}
              class="mt-5 inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
            >
              {if @source_count > 1,
                do: "Open first source request (of #{@source_count})",
                else: "Open source request"}
              <.icon name="hero-arrow-up-right" class="size-4" />
            </.link>
          </section>
        </div>

        <section
          :if={tradeoff_points(@rankings, :speed) != [] or tradeoff_points(@rankings, :cost) != []}
          id="quality-speed-section"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
        >
          <div class="mb-6 flex items-center justify-between">
            <div>
              <h2 class="font-semibold">
                Quality vs. {if @tradeoff_axis == :cost, do: "cost", else: "speed"}
              </h2>
              <p class="text-sm text-base-content/45">
                Selected batch averages — up and left wins. Ringed models are the efficient
                frontier: {if @tradeoff_axis == :cost,
                  do: "no cheaper option scores higher.",
                  else: "no faster option scores higher."}
              </p>
            </div>
            <div class="flex rounded-lg bg-base-200 p-0.5 text-xs">
              <button
                id="tradeoff-axis-speed"
                type="button"
                phx-click="tradeoff_axis"
                phx-value-axis="speed"
                class={[
                  "rounded-md px-2.5 py-1 transition",
                  @tradeoff_axis == :speed && "bg-base-100 font-semibold shadow-sm",
                  @tradeoff_axis != :speed && "text-base-content/50"
                ]}
              >
                Speed
              </button>
              <button
                id="tradeoff-axis-cost"
                type="button"
                phx-click="tradeoff_axis"
                phx-value-axis="cost"
                class={[
                  "rounded-md px-2.5 py-1 transition",
                  @tradeoff_axis == :cost && "bg-base-100 font-semibold shadow-sm",
                  @tradeoff_axis != :cost && "text-base-content/50"
                ]}
              >
                Cost
              </button>
            </div>
          </div>
          <div id="quality-speed-chart" class="overflow-x-auto">
            <svg
              viewBox="0 0 900 280"
              class="min-w-[760px] w-full"
              role="img"
              aria-label="Average score versus average latency by model"
            >
              <line x1="55" y1="20" x2="55" y2="240" stroke="currentColor" class="text-base-300" />
              <line x1="55" y1="240" x2="880" y2="240" stroke="currentColor" class="text-base-300" />
              <text
                :for={tick <- [0, 25, 50, 75, 100]}
                x="18"
                y={chart_y(tick) + 4}
                class="fill-base-content/40 text-[11px]"
              >
                {tick}
              </text>
              <text
                :for={{label, x} <- tradeoff_ticks(@rankings, @tradeoff_axis)}
                x={x}
                y="258"
                text-anchor="middle"
                class="fill-base-content/40 text-[11px]"
              >
                {label}
              </text>
              <g
                :for={{ranking, index} <- tradeoff_points(@rankings, @tradeoff_axis)}
                id={"speed-point-#{index}"}
                class={[
                  "series cursor-pointer",
                  pareto?(ranking, @rankings, @tradeoff_axis) && "pareto"
                ]}
                opacity={
                  series_opacity(
                    @selected_series,
                    "#{ranking.provider}|#{ranking.model}|#{ranking.variant}"
                  )
                }
                phx-click="select_series"
                phx-value-series={"#{ranking.provider}|#{ranking.model}|#{ranking.variant}"}
              >
                <circle
                  :if={pareto?(ranking, @rankings, @tradeoff_axis)}
                  cx={tradeoff_x(ranking, @rankings, @tradeoff_axis)}
                  cy={chart_y(ranking.average)}
                  r="11"
                  fill="none"
                  stroke={chart_color(index)}
                  stroke-width="1.5"
                  stroke-dasharray="3 3"
                />
                <circle
                  cx={tradeoff_x(ranking, @rankings, @tradeoff_axis)}
                  cy={chart_y(ranking.average)}
                  r="7"
                  fill={chart_color(index)}
                >
                  <title>
                    {ranking.provider} / {ranking.model} · score {ranking.average} · {duration(
                      ranking.avg_latency
                    )} · {money(ranking.avg_cost)}
                  </title>
                </circle>
                <text
                  x={tradeoff_x(ranking, @rankings, @tradeoff_axis) + 14}
                  y={chart_y(ranking.average) + 4}
                  class="fill-base-content/60 text-[11px]"
                >
                  {ranking.model}
                </text>
              </g>
            </svg>
          </div>
        </section>

        <section
          id="model-rankings"
          class="overflow-hidden rounded-2xl border border-base-300/60 bg-base-100 shadow-sm"
        >
          <div class="border-b border-base-300/60 p-6">
            <h2 class="text-lg font-semibold">Overall consistency rankings</h2>
            <p class="text-sm text-base-content/45">
              Higher quality and lower deviation indicate dependable models.
            </p>
          </div>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Provider</th>
                  <th>Model</th>
                  <th>Avg score</th>
                  <th>Std dev</th>
                  <th>Range</th>
                  <th>Runs</th>
                  <th>Avg time</th>
                  <th title="Average generation cost per run at pay-as-you-go API list prices">
                    Avg cost
                  </th>
                  <th
                    :if={@source_count > 1}
                    title="This model's average on the source request it handled worst — an aggregate average hides a model that is fine on most requests and catastrophic on a few"
                  >
                    Weakest request
                  </th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for ranking <- @rankings do %>
                  <tr>
                    <td><span class="badge badge-info badge-soft">{ranking.provider}</span></td>
                    <td class="font-mono text-xs">{ranking.model}</td>
                    <td class="font-semibold text-success">{ranking.average || "—"}</td>
                    <td class={deviation_class(ranking.stddev)}>{ranking.stddev}</td>
                    <td>{ranking.min || "—"}–{ranking.max || "—"}</td>
                    <td>{ranking.successful}/{ranking.total}</td>
                    <td>{duration(ranking.avg_latency)}</td>
                    <td class="font-mono text-xs">{money(ranking.avg_cost)}</td>
                    <td :if={@source_count > 1}>
                      <button
                        :if={ranking.per_source != []}
                        type="button"
                        id={"toggle-sources-#{ranking_dom_id(ranking)}"}
                        phx-click="toggle_ranking_sources"
                        phx-value-key={ranking_key(ranking)}
                        class="btn btn-ghost btn-xs gap-1.5"
                        title="Per-request breakdown"
                      >
                        {worst_source_label(ranking)}
                        <.icon
                          name={
                            if MapSet.member?(@expanded_rankings, ranking_key(ranking)),
                              do: "hero-chevron-up",
                              else: "hero-chevron-down"
                          }
                          class="size-3.5"
                        />
                      </button>
                      <span :if={ranking.per_source == []}>—</span>
                    </td>
                    <td>
                      <button
                        :if={is_nil(ranking.variant) && apply_target(@evaluation, ranking)}
                        type="button"
                        id={"apply-#{ranking_dom_id(ranking)}"}
                        phx-click="apply_verdict"
                        phx-value-key={apply_target(@evaluation, ranking)["provider_key_id"]}
                        phx-value-model={ranking.model}
                        data-confirm={"Route this traffic to #{ranking.model}? The routing step that served this benchmark's incumbent will be updated, and the change stays revertible from this page."}
                        class="btn btn-outline btn-xs"
                        title="Update the routing step that served this traffic to this candidate"
                      >
                        Route here
                      </button>
                    </td>
                  </tr>
                  <tr
                    :if={MapSet.member?(@expanded_rankings, ranking_key(ranking))}
                    id={"sources-#{ranking_dom_id(ranking)}"}
                    class="bg-base-200/30"
                  >
                    <td colspan={if @source_count > 1, do: "10", else: "9"} class="px-6 py-3">
                      <p class="mb-2 text-xs font-medium text-base-content/50">
                        Per source request, weakest first
                      </p>
                      <div class="grid gap-1.5">
                        <div
                          :for={source <- ranking.per_source}
                          class="flex flex-wrap items-center gap-4 text-xs"
                        >
                          <.link
                            navigate={~p"/logs/#{source.source_log_id || @evaluation.request_log_id}"}
                            class="font-mono text-primary hover:underline"
                          >
                            {String.slice(source.source_log_id || @evaluation.request_log_id, 0, 8)}
                          </.link>
                          <span class={[
                            "font-semibold",
                            if(source.average, do: "text-success", else: "text-error")
                          ]}>
                            {source.average || "no score"}
                          </span>
                          <span class="text-base-content/45">min {source.min || "—"}</span>
                          <span class="text-base-content/45">
                            {source.successful}/{source.total} scored
                          </span>
                        </div>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <tr :if={@rankings == []}>
                  <td
                    colspan={if @source_count > 1, do: "10", else: "9"}
                    class="py-10 text-center text-base-content/40"
                  >
                    No completed model runs yet.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section
          :if={@projection}
          id="savings-projection"
          class="overflow-hidden rounded-2xl border border-base-300/60 bg-base-100 shadow-sm"
        >
          <div class="border-b border-base-300/60 p-6">
            <h2 class="text-lg font-semibold">Projected at this capture's traffic rate</h2>
            <p :if={is_map(@projection)} class="text-sm text-base-content/45">
              ~{@projection.monthly_requests} requests/month, from {@projection.captured_requests} captured
              over {window_label(@projection.window_seconds)}. Generation cost at API list prices;
              judge spend excluded — production does not pay a judge.
            </p>
          </div>
          <p
            :if={@projection == :window_too_short}
            id="projection-window-note"
            class="p-6 text-sm text-base-content/55"
          >
            This capture spans less than 10 minutes — too short to call its request rate a
            property of your traffic. Record a longer window to get a monthly projection.
          </p>
          <p :if={@projection == :no_traffic} class="p-6 text-sm text-base-content/55">
            The capture holds no requests, so there is no rate to project.
          </p>
          <div :if={is_map(@projection)} class="overflow-x-auto">
            <p
              :if={@projection.baseline_monthly_cost}
              class="px-6 pt-4 text-sm text-base-content/70"
            >
              As served, this traffic projects to <span class="font-semibold">{money(@projection.baseline_monthly_cost)}/month</span>.
            </p>
            <table class="table">
              <thead>
                <tr>
                  <th>Model</th>
                  <th>Avg score</th>
                  <th>Projected /month</th>
                  <th title="Against what the capture's traffic actually cost as served">
                    Savings /month
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @projection.rows}>
                  <td class="font-mono text-xs">
                    {row.model}<span :if={row.variant} class="text-base-content/45"> · {row.variant}</span>
                  </td>
                  <td class="font-semibold text-success">{row.avg_score || "—"}</td>
                  <td class="font-mono text-xs">{money(row.projected_monthly_cost)}</td>
                  <td class={["font-mono text-xs font-semibold", savings_class(row.monthly_savings)]}>
                    {if row.monthly_savings, do: money(row.monthly_savings), else: "—"}
                  </td>
                </tr>
                <tr :if={@projection.rows == []}>
                  <td colspan="4" class="py-8 text-center text-base-content/40">
                    No cost data on the scored runs yet.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section
          :if={@applied_changes != []}
          id="applied-changes"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
        >
          <h2 class="text-lg font-semibold">Routing changes from this benchmark</h2>
          <p class="text-sm text-base-content/45">
            Each change is recorded against the batch that justified it, and stays revertible.
          </p>
          <div class="mt-4 space-y-2">
            <div
              :for={event <- @applied_changes}
              class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-base-300/70 bg-base-200/40 px-4 py-3 text-sm"
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-xs">
                  {event.before_step["model"]}
                  <span :if={event.before_step["provider_key_label"]} class="text-base-content/45">
                    ({event.before_step["provider_key_label"]})
                  </span>
                </span>
                <.icon name="hero-arrow-right" class="size-3.5 text-base-content/40" />
                <span class="font-mono text-xs font-semibold">
                  {event.after_step["model"]}
                  <span :if={event.after_step["provider_key_label"]} class="text-base-content/45">
                    ({event.after_step["provider_key_label"]})
                  </span>
                </span>
                <span class="text-xs text-base-content/45">
                  applied {Calendar.strftime(event.inserted_at, "%b %d, %H:%M")}
                </span>
              </div>
              <span
                :if={event.reverted_at}
                class="badge badge-ghost badge-sm"
                title={"Reverted #{Calendar.strftime(event.reverted_at, "%b %d, %H:%M")}"}
              >
                reverted
              </span>
              <button
                :if={is_nil(event.reverted_at)}
                type="button"
                id={"revert-#{event.id}"}
                phx-click="revert_verdict"
                phx-value-event={event.id}
                data-confirm="Put the routing step back to what it was before this change?"
                class="btn btn-ghost btn-xs"
              >
                Revert
              </button>
            </div>
          </div>
        </section>

        <section :if={@batches == [] or assigns[:selected_group]} class="space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div>
              <h2 class="text-lg font-semibold">Runs</h2>
              <p class="text-sm text-base-content/45">
                Every run in the selected batch.
              </p>
            </div>
            <button
              :if={
                assigns[:selected_group] && @selected_group.errored > 0 &&
                  any_succeeded?(@selected_group)
              }
              id={"toggle-errored-#{@selected_batch}"}
              type="button"
              phx-click="toggle_errored"
              phx-value-batch={@selected_batch}
              class="btn btn-ghost btn-xs gap-1 text-base-content/60"
            >
              <.icon name="hero-exclamation-triangle" class="size-3.5" />
              {if MapSet.member?(@show_errored, @selected_batch),
                do: "Show",
                else: "Hide"} {@selected_group.errored} errored
            </button>
          </div>
          <div id="eval-runs" class="space-y-6">
            <div
              :if={@batches == []}
              id="runs-empty"
              class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-base-content/45"
            >
              No judge runs yet.
            </div>
            <div :if={assigns[:selected_group]} class="space-y-3">
              <p
                :if={visible_runs(@selected_group, @show_errored) == []}
                class="rounded-2xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/45"
              >
                Errored runs are hidden — use the toggle above to bring them back.
              </p>
              <article
                :for={run <- visible_runs(@selected_group, @show_errored)}
                id={"run-#{run.id}"}
                class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm"
              >
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div class="flex items-center gap-3">
                    <span class={[
                      "grid size-12 place-items-center rounded-xl text-lg font-bold",
                      run.status == "completed" && "bg-primary/10 text-primary",
                      run.status == "failed" && "bg-error/10 text-error"
                    ]}>
                      {run.score || "—"}
                    </span>
                    <div>
                      <div class="font-medium">
                        {run.candidate_provider} / {run.candidate_model} · run {run.repetition}<span
                          :if={Evaluations.candidate_key_deleted?(run)}
                          class="ml-1.5 text-xs font-normal text-warning"
                          title={"Answered with #{run.candidate_provider_key_label}, which has since been removed"}
                        >key deleted</span>
                      </div>
                      <%!-- A subtitle, so it is bounded here too: what the
                      column holds is not this template's call to trust. --%>
                      <div class="text-sm text-base-content/60">
                        {one_line(run.summary || run.error) || run_status_label(run, @running?)}
                      </div>
                      <div class="text-xs text-base-content/45">
                        {run.duration_ms || "—"} ms · prompt {run.judge_prompt_version}<span :if={
                          run.judge_provider_key_label
                        }>
                          · judged by {run.judge_provider_key_label}<span
                            :if={Evaluations.judge_key_deleted?(run)}
                            class="text-warning"
                            title="That key has since been removed — this run still names what judged it"
                          >(deleted)</span>
                        </span>
                      </div>
                    </div>
                  </div>
                  <div class="flex flex-wrap items-center justify-end gap-2">
                    <.link
                      :if={run.candidate_log_id}
                      navigate={~p"/logs/#{run.candidate_log_id}"}
                      class="btn btn-ghost btn-sm gap-1.5"
                    >
                      <.icon name="hero-chat-bubble-left-right" class="size-4" /> Candidate log
                    </.link>
                    <.link
                      :if={run.judge_log_id}
                      navigate={~p"/logs/#{run.judge_log_id}"}
                      class="btn btn-ghost btn-sm gap-1.5"
                    >
                      <.icon name="hero-scale" class="size-4" /> Judge log
                    </.link>
                    <span class={[
                      "rounded-full px-2.5 py-1 text-xs font-semibold",
                      run.status == "completed" && "bg-primary/10 text-primary",
                      run.failure_stage == "judge" && "bg-warning/10 text-warning",
                      run.status != "completed" && run.failure_stage != "judge" && "bg-base-200"
                    ]}>
                      {run_status_label(run, @running?)}
                    </span>
                  </div>
                </div>
                <%!-- Everything below the identity line is collapsed. The
                criterion bars, the issue list, the answer and the judge's
                reasoning are each screens tall, and eighteen runs of them is
                not a page anyone reads. --%>
                <details
                  :if={run_has_detail?(run)}
                  id={"run-detail-#{run.id}"}
                  class="group mt-4 border-t border-base-300/40 pt-3"
                >
                  <summary class="cursor-pointer text-sm font-medium text-base-content/60 hover:text-base-content">
                    <.icon
                      name="hero-chevron-right"
                      class="size-3.5 transition-transform group-open:rotate-90"
                    /> {run_detail_label(run)}
                  </summary>
                  <div
                    :if={map_size(run.criterion_scores) > 0}
                    class="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
                  >
                    <div :for={{criterion, value} <- run.criterion_scores}>
                      <div class="mb-1 flex justify-between text-xs">
                        <span>{humanize(criterion)}</span><span>{value}</span>
                      </div>
                      <div class="h-2 overflow-hidden rounded-full bg-base-200">
                        <div class="h-full rounded-full bg-primary" style={"width: #{value}%"}></div>
                      </div>
                    </div>
                  </div>
                  <ul
                    :if={run.issues != []}
                    class="mt-4 list-disc space-y-1 pl-5 text-sm text-base-content/60"
                  >
                    <li :for={issue <- run.issues}>{issue}</li>
                  </ul>
                  <details :if={run.candidate_output not in [nil, ""]} class="group mt-4">
                    <summary class="cursor-pointer text-sm font-medium text-base-content/60 hover:text-base-content">
                      <.icon
                        name="hero-chevron-right"
                        class="size-3.5 transition-transform group-open:rotate-90"
                      />
                      The answer{if run.failure_stage == "judge",
                        do: " — generated and paid for, never scored",
                        else: ""}
                    </summary>
                    <div class="mt-2 max-h-96 overflow-auto rounded-xl bg-base-200/50 p-4 text-sm leading-6 text-base-content/70 whitespace-pre-wrap">
                      {run.candidate_output}
                    </div>
                  </details>
                  <details :if={run.reasoning} class="group mt-4">
                    <summary class="cursor-pointer text-sm font-medium text-base-content/60 hover:text-base-content">
                      <.icon
                        name="hero-chevron-right"
                        class="size-3.5 transition-transform group-open:rotate-90"
                      /> Judge reasoning
                    </summary>
                    <div class="mt-2 rounded-xl bg-base-200/50 p-4 text-sm leading-6 text-base-content/70 whitespace-pre-wrap">
                      {run.reasoning}
                      <div :if={run.rubric_gaps != []} class="mt-3 text-warning">
                        Rubric gaps: {Enum.join(run.rubric_gaps, " · ")}
                      </div>
                    </div>
                  </details>
                </details>
                <details
                  :if={Map.has_key?(@previous_attempts, run.id)}
                  id={"run-attempts-#{run.id}"}
                  class="group mt-3 border-t border-base-300/40 pt-3"
                >
                  <summary class="cursor-pointer text-sm font-medium text-base-content/50 hover:text-base-content">
                    <.icon
                      name="hero-chevron-right"
                      class="size-3.5 transition-transform group-open:rotate-90"
                    />
                    {length(Map.fetch!(@previous_attempts, run.id))} earlier {if length(
                                                                                   Map.fetch!(
                                                                                     @previous_attempts,
                                                                                     run.id
                                                                                   )
                                                                                 ) == 1,
                                                                                 do: "attempt",
                                                                                 else: "attempts"} — replaced by this run
                  </summary>
                  <ul class="mt-2 space-y-2">
                    <li
                      :for={attempt <- Map.fetch!(@previous_attempts, run.id)}
                      class="rounded-xl bg-base-200/40 px-3 py-2 text-sm"
                    >
                      <div class="flex flex-wrap items-baseline justify-between gap-2">
                        <span class="font-medium">
                          {run_status_label(attempt)}{if attempt.score,
                            do: " · #{attempt.score}",
                            else: ""}
                        </span>
                        <span class="text-xs text-base-content/45">
                          {Calendar.strftime(attempt.superseded_at, "%b %-d, %H:%M UTC")}
                        </span>
                      </div>
                      <div :if={attempt.error} class="mt-1 text-base-content/60">
                        {one_line(attempt.error)}
                      </div>
                    </li>
                  </ul>
                </details>
              </article>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm">
      <div class="text-xs font-semibold uppercase tracking-wider text-base-content/40">{@label}</div>
      <div class="mt-2 text-3xl font-semibold tracking-tight">{@value}</div>
      <div class="mt-1 text-xs text-base-content/40">{@detail}</div>
    </div>
    """
  end

  defp score(nil), do: "—"
  defp score(value), do: "#{value}/100"
  defp money(nil), do: "—"
  defp money(value), do: "$" <> Decimal.to_string(Decimal.round(value, 4), :normal)

  # Plan-based keys report $0 actual spend; when the API list-price total
  # diverges, show it as the comparison number.
  defp batch_cost_detail(summary) do
    base = "Batch cost " <> money(summary.total_cost_usd)

    if summary.total_list_cost_usd && summary.total_cost_usd &&
         not Decimal.eq?(summary.total_list_cost_usd, summary.total_cost_usd) do
      base <> " · ~" <> money(summary.total_list_cost_usd) <> " at API rates"
    else
      base
    end
  end

  @summary_limit 240

  defp one_line(nil), do: nil

  defp one_line(text) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) > @summary_limit,
      do: String.slice(collapsed, 0, @summary_limit) <> "…",
      else: collapsed
  end

  defp duration(nil), do: "—"
  defp duration(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 1)}s"
  defp duration(value), do: "#{value}ms"
  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()
  # A judge failure and a candidate failure are not the same news: one means
  # the model never answered, the other that the answer is sitting there
  # unscored. Reading them as the same "Errored" is what made a rate-limited
  # judge look like six models failing.
  defp run_status_label(%{status: "failed", failure_stage: "judge"}), do: "Judge failed"
  defp run_status_label(%{status: "failed"}), do: "Errored"
  defp run_status_label(%{status: "completed"}), do: "Scored"
  defp run_status_label(run), do: String.capitalize(run.status)

  # "Pending" and "Running" are only true while a benchmark is executing.
  # After one stops, the same rows are leftovers, and a row that says
  # "Running" forever is indistinguishable from one that is about to finish.
  defp run_status_label(run, false) when run.status in ["pending", "running"], do: "Interrupted"
  defp run_status_label(run, _running?), do: run_status_label(run)
  defp planned_runs(evaluation), do: length(evaluation.candidate_targets) * evaluation.repetitions

  # Quality tradeoff scatter: one point per ranked model that has both an
  # average score and a value on the chosen axis (speed or cost). Indexes
  # are kept from the full rankings list so colors match the consistency
  # chart and legend.
  defp tradeoff_points(rankings, axis) do
    rankings
    |> Enum.with_index()
    |> Enum.filter(fn {ranking, _index} -> ranking.average && axis_value(ranking, axis) end)
  end

  defp axis_value(ranking, :speed), do: ranking.avg_latency
  defp axis_value(ranking, :cost), do: ranking.avg_cost && Decimal.to_float(ranking.avg_cost)

  # On the efficient frontier: no other model is at least as good on both
  # axes and strictly better on one.
  defp pareto?(ranking, rankings, axis) do
    value = axis_value(ranking, axis)

    not Enum.any?(rankings, fn other ->
      other_value = axis_value(other, axis)

      other.average != nil && other_value != nil &&
        other.average >= ranking.average && other_value <= value &&
        (other.average > ranking.average || other_value < value)
    end)
  end

  defp max_axis(rankings, axis) do
    rankings
    |> Enum.map(&axis_value(&1, axis))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 1 end)
    |> case do
      max when max > 0 -> max
      _zero -> 1
    end
  end

  defp tradeoff_x(ranking, rankings, axis),
    do: 70 + axis_value(ranking, axis) / max_axis(rankings, axis) * 780

  defp tradeoff_ticks(rankings, axis) do
    max = max_axis(rankings, axis)

    for fraction <- [0.25, 0.5, 0.75, 1.0] do
      {axis_tick_label(max * fraction, axis), 70 + fraction * 780}
    end
  end

  defp axis_tick_label(value, :speed), do: duration(round(value))
  defp axis_tick_label(value, :cost), do: money(Decimal.from_float(value))

  defp chart_x(index, total), do: 70 + index * 790 / max(total - 1, 1)
  defp chart_y(nil), do: 240
  defp chart_y(score), do: 240 - score * 2.2

  defp chart_color(index),
    do:
      Enum.at(~w(#6366f1 #f59e0b #10b981 #ef4444 #06b6d4 #a855f7 #ec4899 #84cc16), rem(index, 8))

  defp deviation_class(value) when value <= 5, do: "font-semibold text-success"
  defp deviation_class(value) when value <= 12, do: "font-semibold text-warning"
  defp deviation_class(_value), do: "font-semibold text-error"
end
