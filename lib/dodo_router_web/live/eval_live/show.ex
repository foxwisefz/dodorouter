defmodule DodoRouterWeb.EvalLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(DodoRouter.PubSub, "evaluation:#{id}")

    case Evaluations.get_evaluation(socket.assigns.current_user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Evaluation not found")
         |> push_navigate(to: ~p"/evals")}

      evaluation ->
        socket =
          socket
          |> assign(:show_errored, MapSet.new())
          |> assign(:selected_series, nil)
          |> load(evaluation)

        if params["run"] == "true" do
          {:ok, start_benchmark(socket)}
        else
          {:ok, socket}
        end
    end
  end

  @impl true
  def handle_event("run", _params, socket) do
    {:noreply, start_benchmark(socket)}
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
    |> assign(:running?, Evaluations.benchmark_running?(evaluation))
  end

  # One entry per ranked model: scored runs positioned by repetition slot
  # (so an errored repetition leaves a visible gap in the line). Errored
  # runs stay off the chart — they surface as legend counts only.
  defp chart_series(batch_runs, rankings) do
    slots =
      batch_runs
      |> Enum.map(& &1.repetition)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> length(batch_runs) end)
      |> max(2)

    rankings
    |> Enum.with_index()
    |> Enum.map(fn {ranking, index} ->
      points =
        batch_runs
        |> Enum.filter(
          &(&1.candidate_provider == ranking.provider and
              &1.candidate_model == ranking.model)
        )
        |> Enum.sort_by(& &1.repetition)
        |> Enum.with_index()
        |> Enum.map(fn {run, idx} ->
          %{
            run: run,
            x: chart_x((run.repetition || idx + 1) - 1, slots),
            scored?: run.status == "completed" and is_integer(run.score)
          }
        end)

      %{
        key: "#{ranking.provider}|#{ranking.model}",
        provider: ranking.provider,
        model: ranking.model,
        color: chart_color(index),
        points: points
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
    if MapSet.member?(show_errored, batch.dom_id),
      do: batch.runs,
      else: Enum.reject(batch.runs, &(&1.status == "failed"))
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
                <span class="rounded-full bg-base-200 px-2.5 py-1">
                  Source: {@evaluation.request_log.final_provider} / {@evaluation.request_log.final_model}
                </span>
                <span class="rounded-full bg-primary/10 px-2.5 py-1 text-primary">
                  Judge: {@evaluation.judge_model}
                </span>
              </div>
            </div>
          </div>
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
            detail={"Batch cost " <> money(@summary.total_cost_usd)}
          />
          <.stat
            label="Errored runs"
            value={to_string(@summary.failed)}
            detail={percent(@summary.pass_rate) <> " pass rate"}
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
                <line
                  x1="55"
                  y1="86"
                  x2="880"
                  y2="86"
                  stroke="currentColor"
                  stroke-dasharray="6 6"
                  class="text-success/50"
                />
                <text x="60" y="80" class="fill-success text-[11px]">Pass 70</text>
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
            <.link
              navigate={~p"/logs/#{@evaluation.request_log.id}"}
              class="mt-5 inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
            >
              Open source request <.icon name="hero-arrow-up-right" class="size-4" />
            </.link>
          </section>
        </div>

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
                  <th>Pass rate</th>
                  <th>Runs</th>
                  <th>Avg time</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ranking <- @rankings}>
                  <td><span class="badge badge-info badge-soft">{ranking.provider}</span></td>
                  <td class="font-mono text-xs">{ranking.model}</td>
                  <td class="font-semibold text-success">{ranking.average || "—"}</td>
                  <td class={deviation_class(ranking.stddev)}>{ranking.stddev}</td>
                  <td>{ranking.min || "—"}–{ranking.max || "—"}</td>
                  <td>{percent(ranking.pass_rate)}</td>
                  <td>{ranking.successful}/{ranking.total}</td>
                  <td>{duration(ranking.avg_latency)}</td>
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
                  :if={batch.errored > 0}
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
                      run.passed && "bg-success/10 text-success",
                      run.status == "completed" && !run.passed && "bg-warning/10 text-warning",
                      run.status == "failed" && "bg-error/10 text-error"
                    ]}>
                      {run.score || "—"}
                    </span>
                    <div>
                      <div class="font-medium">
                        {run.candidate_provider} / {run.candidate_model} · run {run.repetition}
                      </div>
                      <div class="text-sm text-base-content/60">
                        {run.summary || run.error || run_status_label(run)}
                      </div>
                      <div class="text-xs text-base-content/45">
                        {run.duration_ms || "—"} ms · prompt {run.judge_prompt_version}
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
                      run.passed && "bg-success/10 text-success",
                      !run.passed && "bg-base-200"
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
  defp percent(nil), do: "—"
  defp percent(value), do: "#{value}%"
  defp money(nil), do: "—"
  defp money(value), do: "$" <> Decimal.to_string(Decimal.round(value, 4), :normal)
  defp duration(nil), do: "—"
  defp duration(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 1)}s"
  defp duration(value), do: "#{value}ms"
  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()
  defp run_status_label(%{status: "failed"}), do: "Errored"
  defp run_status_label(%{status: "completed", passed: true}), do: "Passed"
  defp run_status_label(%{status: "completed"}), do: "Not passed"
  defp run_status_label(run), do: String.capitalize(run.status)
  defp planned_runs(evaluation), do: length(evaluation.candidate_targets) * evaluation.repetitions

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
