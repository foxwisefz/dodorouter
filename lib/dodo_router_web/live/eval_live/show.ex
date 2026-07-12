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
        socket = load(socket, evaluation)

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
    socket
    |> assign(:page_title, evaluation.name)
    |> assign(:evaluation, evaluation)
    |> assign(:summary, Evaluations.summary(evaluation))
    |> assign(:rankings, Evaluations.rankings(evaluation))
    |> assign(:running?, evaluation.benchmark_status == "running")
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
                {@summary.runs} of {planned_runs(@evaluation)} candidate runs finished. Scores and rankings update as each result lands.
              </div>
            </div>
          </div>
          <progress
            class="progress progress-primary mt-4 w-full"
            value={@summary.runs}
            max={planned_runs(@evaluation)}
          >
          </progress>
        </div>

        <div id="eval-summary" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat
            label="Total runs"
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
            detail="Candidate generation latency"
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
                <h2 class="font-semibold">Quality trend</h2>
                <p class="text-sm text-base-content/45">Score consistency across judge runs</p>
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
                <g :for={{ranking, index} <- Enum.with_index(@rankings)}>
                  <polyline
                    fill="none"
                    stroke={chart_color(index)}
                    stroke-width="3"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    points={chart_points(@evaluation.runs, ranking)}
                  />
                  <circle
                    :for={{run, point_index} <- chart_runs(@evaluation.runs, ranking)}
                    cx={chart_x(point_index, max(ranking.total, 2))}
                    cy={chart_y(run.score)}
                    r="5"
                    fill={chart_color(index)}
                  >
                    <title>{ranking.model}: {run.score}</title>
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
              <div class="mt-3 flex flex-wrap gap-3">
                <span
                  :for={{ranking, index} <- Enum.with_index(@rankings)}
                  class="flex items-center gap-1.5 text-xs"
                >
                  <i class="size-2.5 rounded-full" style={"background: #{chart_color(index)}"}></i>{ranking.provider} / {ranking.model}
                </span>
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
          <h2 class="text-lg font-semibold">Run history</h2>
          <div id="eval-runs" class="space-y-3">
            <div
              :if={@evaluation.runs == []}
              id="runs-empty"
              class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-base-content/45"
            >
              No judge runs yet.
            </div>
            <article
              :for={run <- Enum.reverse(@evaluation.runs)}
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
  defp duration(nil), do: "—"
  defp duration(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 1)}s"
  defp duration(value), do: "#{value}ms"
  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()
  defp run_status_label(%{status: "failed"}), do: "Errored"
  defp run_status_label(%{status: "completed", passed: true}), do: "Passed"
  defp run_status_label(%{status: "completed"}), do: "Not passed"
  defp run_status_label(run), do: String.capitalize(run.status)
  defp planned_runs(evaluation), do: length(evaluation.candidate_targets) * evaluation.repetitions

  defp chart_runs(runs, ranking) do
    runs
    |> Enum.filter(
      &(&1.status == "completed" and &1.candidate_provider == ranking.provider and
          &1.candidate_model == ranking.model)
    )
    |> Enum.sort_by(& &1.repetition)
    |> Enum.with_index()
  end

  defp chart_points(runs, ranking) do
    runs
    |> chart_runs(ranking)
    |> Enum.map_join(" ", fn {run, index} ->
      "#{chart_x(index, max(ranking.total, 2))},#{chart_y(run.score)}"
    end)
  end

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
