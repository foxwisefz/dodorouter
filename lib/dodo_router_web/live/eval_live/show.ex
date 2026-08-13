defmodule DodoRouterWeb.EvalLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations

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
         |> assign(:selected_series, nil)
         |> assign(:tradeoff_axis, :speed)
         |> load(evaluation)}
    end
  end

  @impl true
  def handle_event("run", _params, socket) do
    {:noreply, start_benchmark(socket)}
  end

  def handle_event("retry_failed", _params, socket) do
    user = socket.assigns.current_user
    evaluation = socket.assigns.evaluation

    if Evaluations.benchmark_running?(evaluation) do
      {:noreply, put_flash(socket, :error, "A benchmark is already running")}
    else
      {:ok, _results} = Evaluations.retry_failed(user, evaluation)

      {:noreply,
       socket
       |> load(Evaluations.get_evaluation!(user, evaluation.id))
       |> put_flash(:info, "Retried the failed runs")}
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

    {:noreply, socket |> load(evaluation) |> put_flash(:info, "Benchmark completed")}
  end

  def handle_info({:benchmark_progress, _result}, socket) do
    evaluation =
      Evaluations.get_evaluation!(socket.assigns.current_user, socket.assigns.evaluation.id)

    {:noreply, load(socket, evaluation)}
  end

  def handle_info({:benchmark_finished, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> put_flash(:error, "Benchmark stopped: #{inspect(reason)}")}
  end

  defp start_benchmark(socket) do
    user = socket.assigns.current_user
    evaluation = socket.assigns.evaluation

    case Evaluations.enqueue(user, evaluation) do
      :ok ->
        assign(socket, :running?, true)

      {:error, :already_running} ->
        assign(socket, :running?, true)

      {:error, reason} ->
        put_flash(socket, :error, "Could not start benchmark: #{inspect(reason)}")
    end
  end

  defp load(socket, evaluation) do
    batch_runs = Evaluations.latest_batch_runs(evaluation)
    rankings = Evaluations.rankings(evaluation)

    socket
    |> assign(:page_title, evaluation.name)
    |> assign(:evaluation, evaluation)
    |> assign(:batch_runs, batch_runs)
    |> assign(:batches, group_batches(evaluation))
    |> assign(:summary, Evaluations.summary(evaluation))
    |> assign(:rankings, rankings)
    |> assign(:chart_series, chart_series(batch_runs, rankings))
    |> assign(:rubric_feedback, Evaluations.rubric_feedback(batch_runs))
    |> assign(:retryable, Evaluations.retryable_counts(evaluation))
    |> assign(:shared_key_label, shared_key_label(evaluation))
    |> assign(:running?, Evaluations.benchmark_running?(evaluation))
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
                &1.candidate_model == ranking.model)
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
        key: "#{ranking.provider}|#{ranking.model}",
        provider: ranking.provider,
        model: ranking.model,
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

  defp visible_runs(batch, show_errored) do
    cond do
      MapSet.member?(show_errored, batch.dom_id) -> batch.runs
      # Hiding every row and offering a toggle is not a summary, it is an
      # empty page with homework. When nothing succeeded, the errors are
      # the result.
      not any_succeeded?(batch) -> batch.runs
      true -> Enum.reject(batch.runs, &(&1.status == "failed"))
    end
  end

  defp any_succeeded?(batch), do: Enum.any?(batch.runs, &(&1.status != "failed"))

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
                <span class="rounded-full bg-base-200 px-2.5 py-1">
                  Source: {@evaluation.request_log.final_provider} / {@evaluation.request_log.final_model}
                </span>
                <span class="rounded-full bg-primary/10 px-2.5 py-1 text-primary">
                  Judge: {@evaluation.judge_model}
                </span>
                <span
                  :if={@evaluation.benchmark_status not in [nil, "draft", "completed"]}
                  id="eval-status"
                  class={[
                    "rounded-full px-2.5 py-1",
                    @evaluation.benchmark_status == "failed" && "bg-error/10 text-error",
                    @evaluation.benchmark_status == "partial" && "bg-warning/10 text-warning",
                    @evaluation.benchmark_status == "running" && "bg-primary/10 text-primary"
                  ]}
                >
                  Last run: {@evaluation.benchmark_status}
                </span>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-2">
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
              title="Repeats only what failed, reusing answers already paid for"
            >
              <.icon name="hero-arrow-uturn-left" class="size-4" />
              Retry failed ({retry_description(@retryable)})
            </button>
            <button
              id="run-eval-button"
              phx-click="run"
              disabled={@running?}
              class="btn btn-primary gap-2"
            >
              <.icon name="hero-play" class="size-4" /> {if @running?,
                do: "Benchmark running…",
                else: "Run again"}
            </button>
          </div>
        </div>

        <div
          :if={@running?}
          id="eval-progress"
          class="rounded-2xl border border-primary/20 bg-primary/5 p-5"
        >
          <div class="flex items-center gap-3">
            <.icon name="hero-arrow-path" class="size-5 animate-spin text-primary" />
            <div>
              <div class="font-semibold">Live benchmark</div>
              <div class="text-sm text-base-content/50">
                {min(@summary.runs, planned_runs(@evaluation))} of {planned_runs(@evaluation)} candidate runs finished. Scores and rankings update as each result lands.
              </div>
            </div>
          </div>
          <progress
            class="progress progress-primary mt-4 w-full"
            value={min(@summary.runs, planned_runs(@evaluation))}
            max={planned_runs(@evaluation)}
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

        <div id="eval-summary" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat
            label="Latest batch runs"
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

        <div class="grid gap-6 lg:grid-cols-[1.4fr_1fr]">
          <section
            id="score-trend"
            class="rounded-2xl border border-base-300/60 bg-base-100 p-6 shadow-sm"
          >
            <div class="mb-6 flex items-center justify-between">
              <div>
                <h2 class="font-semibold">Score consistency</h2>
                <p class="text-sm text-base-content/45">
                  Judge scores per repetition, latest batch
                </p>
              </div>
              <span class="text-xs text-base-content/40">0–100</span>
            </div>
            <div id="quality-consistency-chart" class="overflow-x-auto">
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
            <p class="mt-3 whitespace-pre-wrap text-sm leading-6 text-base-content/70">
              {@evaluation.criteria}
            </p>
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
              Open source request <.icon name="hero-arrow-up-right" class="size-4" />
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
                Latest batch averages — up and left wins. Ringed models are the efficient
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
                opacity={series_opacity(@selected_series, "#{ranking.provider}|#{ranking.model}")}
                phx-click="select_series"
                phx-value-series={"#{ranking.provider}|#{ranking.model}"}
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
                </tr>
              </thead>
              <tbody>
                <tr :for={ranking <- @rankings}>
                  <td><span class="badge badge-info badge-soft">{ranking.provider}</span></td>
                  <td class="font-mono text-xs">{ranking.model}</td>
                  <td class="font-semibold text-success">{ranking.average || "—"}</td>
                  <td class={deviation_class(ranking.stddev)}>{ranking.stddev}</td>
                  <td>{ranking.min || "—"}–{ranking.max || "—"}</td>
                  <td>{ranking.successful}/{ranking.total}</td>
                  <td>{duration(ranking.avg_latency)}</td>
                  <td class="font-mono text-xs">{money(ranking.avg_cost)}</td>
                </tr>
                <tr :if={@rankings == []}>
                  <td colspan="8" class="py-10 text-center text-base-content/40">
                    No completed model runs yet.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="space-y-3">
          <div>
            <h2 class="text-lg font-semibold">Run history</h2>
            <p class="text-sm text-base-content/45">
              All benchmark executions; stats above cover only the latest.
            </p>
          </div>
          <div id="eval-runs" class="space-y-6">
            <div
              :if={@batches == []}
              id="runs-empty"
              class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-base-content/45"
            >
              No judge runs yet.
            </div>
            <div :for={batch <- @batches} id={"batch-#{batch.dom_id}"} class="space-y-3">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="flex items-center gap-2 text-sm">
                  <span class="font-semibold">
                    {if batch.latest?, do: "Latest batch", else: "Batch"}
                  </span>
                  <span class="text-base-content/45">
                    {Calendar.strftime(batch.started_at, "%b %-d, %H:%M UTC")}
                  </span>
                  <span class="rounded-full bg-base-200 px-2 py-0.5 text-xs">
                    {length(batch.runs)} runs
                  </span>
                </div>
                <button
                  :if={batch.errored > 0 and any_succeeded?(batch)}
                  id={"toggle-errored-#{batch.dom_id}"}
                  type="button"
                  phx-click="toggle_errored"
                  phx-value-batch={batch.dom_id}
                  class="btn btn-ghost btn-xs gap-1 text-base-content/60"
                >
                  <.icon name="hero-exclamation-triangle" class="size-3.5" />
                  {if MapSet.member?(@show_errored, batch.dom_id),
                    do: "Hide",
                    else: "Show"} {batch.errored} errored
                </button>
              </div>
              <p
                :if={visible_runs(batch, @show_errored) == []}
                class="rounded-2xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/45"
              >
                Every run in this batch errored — use the toggle above to inspect them.
              </p>
              <article
                :for={run <- visible_runs(batch, @show_errored)}
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
                        {one_line(run.summary || run.error) || run_status_label(run)}
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
                      {run_status_label(run)}
                    </span>
                  </div>
                </div>
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
