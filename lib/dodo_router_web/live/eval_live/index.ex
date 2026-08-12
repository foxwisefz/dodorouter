defmodule DodoRouterWeb.EvalLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations

  @impl true
  def mount(_params, _session, socket) do
    evaluations = Evaluations.list_evaluations(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Evaluations")
     |> assign(:empty?, evaluations == [])
     |> assign(:agent_base, DodoRouterWeb.Endpoint.url())
     |> stream(:evaluations, evaluations)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl space-y-6">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">Quality lab</p>
          <h1 class="text-3xl font-semibold tracking-tight">Evaluations</h1>
          <p class="mt-1 text-base-content/55">
            Reusable, judge-scored tests created from production requests.
          </p>
        </div>

        <div id="evaluations" phx-update="stream" class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          <div
            id="evals-empty"
            class="hidden only:block rounded-2xl border border-dashed border-base-300 p-12 text-center text-base-content/50"
          >
            Select a request log and choose “Create eval” to get started.
          </div>
          <.link
            :for={{id, evaluation} <- @streams.evaluations}
            id={id}
            navigate={~p"/evals/#{evaluation.id}"}
            class="group rounded-2xl border border-base-300/60 bg-base-100 p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-lg"
          >
            <div class="flex items-start justify-between gap-3">
              <h2 class="font-semibold group-hover:text-primary">{evaluation.name}</h2>
              <span class="rounded-full bg-base-200 px-2 py-1 text-xs">
                {evaluation.run_count} runs
              </span>
            </div>
            <p class="mt-3 line-clamp-2 text-sm text-base-content/55">{evaluation.criteria}</p>
            <div class="mt-5 flex items-center justify-between text-xs text-base-content/45">
              <span class="font-mono">{evaluation.request_log.final_model}</span>
              <span>Judge: {evaluation.judge_model}</span>
            </div>
          </.link>
        </div>

        <div
          :if={@nav_routers != []}
          id="agent-access"
          class="rounded-2xl border border-base-300/60 bg-base-100 p-5"
        >
          <h2 class="font-semibold">Run evals from your coding agent</h2>
          <p class="mt-1 max-w-2xl text-sm text-base-content/55">
            Give your agent a router's API key and this one command. It reads back the whole
            workflow — find a real request, replay it on other models, score the answers — so it
            can compare quality against price without you in the loop.
          </p>

          <div class="mt-4 space-y-2">
            <div :for={router <- @nav_routers} class="text-sm">
              <span class="text-xs uppercase tracking-wider text-base-content/45">
                {router.name}
              </span>
              <code class="mt-1 block overflow-x-auto rounded-lg bg-base-200/70 px-3 py-2 font-mono text-xs">
                curl -H "Authorization: Bearer $DODO_API_KEY" {@agent_base}/r/{router.slug}/agent
              </code>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
