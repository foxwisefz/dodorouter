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
              <div
                :for={scope <- @scopes}
                class={[
                  "rounded-xl border p-3",
                  scope.sensitive? && "border-warning/40 bg-warning/5",
                  !scope.sensitive? && "border-base-300/60"
                ]}
              >
                <div class="flex items-center gap-2 text-sm font-medium">
                  {scope.label}
                  <span
                    :if={scope.sensitive?}
                    class="rounded-full bg-warning/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-warning"
                  >
                    Sensitive
                  </span>
                </div>
                <p class="mt-0.5 text-xs text-base-content/55">{scope.description}</p>
              </div>

              <p :if={@scopes == []} class="text-sm text-base-content/55">
                No permissions requested.
              </p>
            </div>

            <div class="mt-7 flex items-center gap-3">
              <.form for={%{}} action={~p"/oauth/consent"} method="post" class="flex-1">
                <input :for={{k, v} <- @authorize_params} type="hidden" name={k} value={v} />
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
