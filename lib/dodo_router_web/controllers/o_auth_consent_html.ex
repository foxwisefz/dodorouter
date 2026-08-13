defmodule DodoRouterWeb.OAuthConsentHTML do
  use DodoRouterWeb, :html

  @doc """
  The approval screen.

  Deliberately plain and slightly severe: this is the moment a user grants a
  program access to their product's traffic, and it should read as a decision
  rather than a formality. Sensitive scopes are visually separated, and the
  client's self-declared name is shown as a claim, not a fact.
  """
  def show(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Authorize an agent · DodoRouter</title>
        <%!-- Stylesheet only. Deliberately no app.js: this page is a form, and
              pulling in the LiveView client would open a socket for a LiveView
              that does not exist. --%>
        <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body class="bg-base-200/40">
        <main class="mx-auto flex min-h-screen max-w-lg flex-col justify-center px-6 py-12">
          <div class="rounded-2xl border border-base-300/60 bg-base-100 p-7 shadow-sm">
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">
              Authorize an agent
            </p>

            <h1 class="mt-2 text-2xl font-semibold tracking-tight">
              {client_label(@client)}
              <span class="font-normal text-base-content/55">wants access</span>
            </h1>

            <p class="mt-2 text-sm text-base-content/55">
              Signing in as <span class="font-medium text-base-content">{@user.email}</span>.
            </p>

            <p
              :if={@client && @client.registered_by_id == nil}
              class="mt-4 rounded-xl border border-base-300/60 bg-base-200/40 px-3 py-2 text-xs text-base-content/60"
            >
              This application registered itself and chose its own name. Only approve it if you
              just started it yourself.
            </p>

            <div class="mt-6 space-y-2">
              <label
                :for={scope <- @scopes}
                class={[
                  "flex cursor-pointer items-start gap-3 rounded-xl border p-3 transition-colors",
                  scope.sensitive? && "border-warning/40 bg-warning/5 hover:border-warning/60",
                  !scope.sensitive? && "border-base-300/60 hover:border-primary/40"
                ]}
              >
                <%!-- Offered ticked, because the client asked for it and silently
                      dropping a scope would break the agent — but declinable. A
                      screen that only lists permissions is a notice, not consent. --%>
                <input
                  type="checkbox"
                  name="granted_scopes[]"
                  value={scope.name}
                  checked
                  form="consent-approve"
                  class="mt-0.5 size-4 rounded border-base-300"
                />
                <span class="min-w-0">
                  <span class="flex items-center gap-2 text-sm font-medium">
                    {scope.label}
                    <span
                      :if={scope.sensitive?}
                      class="rounded-full bg-warning/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-warning"
                    >
                      Sensitive
                    </span>
                  </span>
                  <span class="mt-0.5 block text-xs text-base-content/55">{scope.description}</span>
                  <code class="mt-1 block font-mono text-[11px] text-base-content/35">
                    {scope.name}
                  </code>
                </span>
              </label>

              <p :if={@scopes == []} class="text-sm text-base-content/55">
                No permissions requested.
              </p>
            </div>

            <div class="mt-7 flex items-center gap-3">
              <.form
                for={%{}}
                action={~p"/oauth/consent"}
                method="post"
                id="consent-approve"
                class="flex-1"
              >
                <%!-- `scope` is excluded on purpose: the checkboxes carry it, so
                      what is granted is exactly what was ticked. --%>
                <input
                  :for={{k, v} <- Enum.reject(@authorize_params, &(elem(&1, 0) == "scope"))}
                  type="hidden"
                  name={k}
                  value={v}
                />
                <input type="hidden" name="decision" value="approve" />
                <button
                  id="approve-consent"
                  type="submit"
                  class="w-full rounded-xl bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content transition hover:opacity-90"
                >
                  Authorize
                </button>
              </.form>

              <.form for={%{}} action={~p"/oauth/consent"} method="post">
                <input :for={{k, v} <- @authorize_params} type="hidden" name={k} value={v} />
                <input type="hidden" name="decision" value="deny" />
                <button
                  id="deny-consent"
                  type="submit"
                  class="rounded-xl border border-base-300/60 px-4 py-2.5 text-sm font-medium transition hover:border-error/40 hover:text-error"
                >
                  Refuse
                </button>
              </.form>
            </div>

            <p :if={@error} class="mt-4 text-sm text-error">{@error}</p>

            <p class="mt-5 text-xs text-base-content/45">
              You can revoke this at any time from Agent tokens. Every call it makes is recorded.
            </p>
          </div>
        </main>
      </body>
    </html>
    """
  end

  defp client_label(nil), do: "An application"
  defp client_label(%{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_label(_client), do: "An application"
end
