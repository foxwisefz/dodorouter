defmodule DodoRouterWeb.AgentActivityLive.Index do
  @moduledoc """
  What agents connected to this account have been doing.

  Agents authenticate over OAuth, so there is no credential to mint here — a
  client registers itself and the user approves it on the consent screen. What
  is left, and what this page exists for, is the half that outlives any single
  access token: which clients are connected, and every call they made.

  Refused calls are the ones worth surfacing. A page that only showed successes
  could not distinguish "nothing went wrong" from "we have no way to tell".
  """

  use DodoRouterWeb, :live_view

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Scopes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent activity")
     |> assign(:base_url, DodoRouterWeb.Endpoint.url())
     |> assign(:outcome, nil)
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:clients, Agents.list_clients(user))
    |> assign(:calls, Agents.list_calls(user, limit: 50, outcome: socket.assigns.outcome))
    |> assign(:totals, Agents.call_stats(user))
  end

  @impl true
  def handle_event("filter", %{"outcome" => outcome}, socket) do
    {:noreply,
     socket
     |> assign(:outcome, if(outcome == "", do: nil, else: outcome))
     |> load()}
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl space-y-8">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">Agent access</p>
          <h1 class="text-3xl font-semibold tracking-tight">Agent activity</h1>
          <p class="mt-1 max-w-2xl text-base-content/55">
            Coding agents connect over OAuth and read your traffic to run evaluations. Every call
            they make is recorded here, including the ones that were refused.
          </p>
        </div>

        <.connect_card base_url={@base_url} />

        <.clients clients={@clients} />

        <.audit_trail calls={@calls} totals={@totals} outcome={@outcome} />
      </div>
    </Layouts.app>
    """
  end

  defp connect_card(assigns) do
    ~H"""
    <section id="connect-agent" class="rounded-2xl border border-base-300/60 bg-base-100 p-5">
      <h2 class="text-lg font-semibold">Connect an agent</h2>
      <p class="mt-1 max-w-2xl text-sm text-base-content/55">
        One command. The agent registers itself, you approve it in the browser with the session
        you already have, and no secret is ever written to a config file.
      </p>

      <code
        phx-no-curly-interpolation
        class="mt-3 block overflow-x-auto rounded-lg bg-base-200/70 px-3 py-2 font-mono text-xs"
      >
        claude mcp add --transport http dodorouter {@base_url}/mcp
      </code>

      <p class="mt-3 text-xs text-base-content/45">
        You choose what it may read when you approve it. Reading prompts and responses is a
        separate permission from reading models, tokens and cost.
      </p>

      <div class="mt-3 flex flex-wrap gap-1.5">
        <span
          :for={scope <- Scopes.all()}
          class={[
            "rounded-full px-2 py-0.5 font-mono text-[11px]",
            scope.sensitive? && "bg-warning/15 text-warning",
            !scope.sensitive? && "bg-base-200 text-base-content/60"
          ]}
          title={scope.description}
        >
          {scope.name}
        </span>
      </div>
    </section>
    """
  end

  defp clients(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-lg font-semibold">Connected agents</h2>

      <p
        :if={@clients == []}
        class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-base-content/50"
      >
        Nothing connected yet. Run the command above and approve it.
      </p>

      <div
        :for={client <- @clients}
        id={"client-#{Base.url_encode64(client.name, padding: false)}"}
        class="rounded-2xl border border-base-300/60 bg-base-100 p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="font-semibold">{client.name}</p>
            <p class="mt-0.5 text-xs text-base-content/55">
              {client.calls} calls · last seen {Calendar.strftime(
                client.last_seen_at,
                "%b %d %H:%M"
              )}
            </p>
            <%!-- Reading transcript text is the permission a user would want to
                  know was actually exercised, not merely granted. --%>
            <p :if={client.read_bodies > 0} class="mt-1 text-xs text-warning">
              Read prompt or response text on {client.read_bodies} calls
            </p>
          </div>

          <div
            :if={client.denied > 0}
            class="rounded-lg bg-error/10 px-2.5 py-1.5 text-center"
          >
            <p class="text-sm font-semibold text-error">{client.denied}</p>
            <p class="text-[10px] uppercase tracking-wide text-error/70">denied</p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp audit_trail(assigns) do
    ~H"""
    <section class="space-y-3">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-semibold">What agents did</h2>

        <div class="flex items-center gap-1">
          <button
            :for={
              {label, value} <- [
                {"All", ""},
                {"Allowed", "ok"},
                {"Denied", "denied"},
                {"Errored", "error"}
              ]
            }
            id={"filter-#{if value == "", do: "all", else: value}"}
            phx-click="filter"
            phx-value-outcome={value}
            class={[
              "rounded-lg px-2.5 py-1 text-xs transition-colors",
              (@outcome || "") == value && "bg-primary/10 font-medium text-primary",
              (@outcome || "") != value && "text-base-content/55 hover:bg-base-200"
            ]}
          >
            {label}
            <span :if={value != ""} class="text-base-content/40">
              {Map.get(@totals, value, 0)}
            </span>
          </button>
        </div>
      </div>

      <div class="overflow-hidden rounded-2xl border border-base-300/60 bg-base-100">
        <p :if={@calls == []} class="p-10 text-center text-base-content/50">
          Nothing yet. Calls appear here the moment an agent connects.
        </p>

        <table :if={@calls != []} class="w-full text-sm">
          <thead class="border-b border-base-300/60 text-left text-xs uppercase tracking-wide text-base-content/45">
            <tr>
              <th class="px-4 py-2 font-medium">When</th>
              <th class="px-4 py-2 font-medium">Agent</th>
              <th class="px-4 py-2 font-medium">Operation</th>
              <th class="px-4 py-2 font-medium">Result</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={call <- @calls}
              id={"call-#{call.id}"}
              class={[
                "border-b border-base-300/40 last:border-0",
                call.outcome == "denied" && "bg-error/5"
              ]}
            >
              <td class="whitespace-nowrap px-4 py-2 text-xs text-base-content/55">
                {Calendar.strftime(call.inserted_at, "%b %d %H:%M:%S")}
              </td>
              <td class="px-4 py-2">
                <span class="text-xs">{call.principal_name || "—"}</span>
                <span
                  :if={call.principal_kind == "unauthenticated"}
                  class="ml-1 rounded bg-error/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-error"
                >
                  no credential
                </span>
              </td>
              <td class="px-4 py-2">
                <code class="font-mono text-xs">{call.tool || call.operation}</code>
                <span
                  :if={call.returned_bodies}
                  class="ml-1.5 rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-warning"
                  title="This response carried prompt or response text"
                >
                  bodies
                </span>
              </td>
              <td class="whitespace-nowrap px-4 py-2">
                <span class={[
                  "rounded-full px-2 py-0.5 text-[11px] font-medium",
                  call.outcome == "ok" && "bg-success/15 text-success",
                  call.outcome == "denied" && "bg-error/15 text-error",
                  call.outcome == "error" && "bg-base-200 text-base-content/60"
                ]}>
                  {call.outcome} {call.http_status}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end
end
