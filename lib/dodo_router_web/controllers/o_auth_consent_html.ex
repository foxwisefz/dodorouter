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
    <html lang="en" data-theme={(@user && @user.theme) || "light"}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Authorize an agent · DodoRouter</title>
        <%= if Application.get_env(:dodo_router, :env) == :dev do %>
          <link
            rel="icon"
            type="image/svg+xml"
            href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='32' height='32' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='16' r='14' fill='%23f97316'/%3E%3Ctext x='16' y='21' font-family='Arial' font-size='14' font-weight='bold' fill='white' text-anchor='middle'%3ED%3C/text%3E%3C/svg%3E"
          />
        <% else %>
          <link
            rel="icon"
            type="image/svg+xml"
            href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='38' height='40' viewBox='0 0 38 40' fill='none'%3E%3Cpath d='M32.4355 3.10127C31.2294 2.97468 28.8809 3.03797 27.3575 3.10127C26.9132 1.89873 25.2628 0 22.343 0C18.9154 0 15.8686 2.40506 15.8686 7.08861C15.8686 10.6962 17.8363 13.1013 19.1058 15.2532C17.2651 14.8734 11.6793 14.6203 7.48999 20C6.4744 18.2911 5.33186 17.4051 3.87194 17.4051C2.03118 17.4051 0.761694 19.1772 1.90423 21.3924C0.952117 21.3924 0 22.0886 0 23.6709C0 24.6835 0.507796 25.5063 1.45991 26.0759C1.01559 26.7089 0.888643 29.6203 4.06237 29.6203C4.57016 29.6203 5.33186 29.4304 5.64923 29.3038C6.60135 32.3418 9.14033 33.5443 11.3619 34.1772L11.9332 36.2658C11.1715 36.5823 10.4098 37.1519 10.4098 38.1013L10.4733 39.8101L29.1348 40C29.5156 38.1013 28.7539 36.3291 27.1036 36.2658L24.755 36.2025L23.676 33.3544C26.088 32.6582 33.0702 30.6962 33.0702 23.2911C33.0702 17.7848 29.1983 15.3165 27.7383 12.1519C29.0078 11.962 30.9121 11.7722 32.1181 11.7089C33.1972 11.7089 34.1493 12.4051 34.2762 13.9873C34.3397 14.6203 37.4499 14.3038 37.9577 10.1266C38.3386 6.77215 36.117 3.41772 32.4355 3.10127ZM19.4867 38.6076H11.9967C11.8697 37.6582 13.7105 37.8481 13.774 37.3418C13.8374 36.8987 13.0123 35.1266 12.9488 34.557L13.7105 33.9873C13.9009 33.7342 13.9009 33.2278 12.441 32.9747C10.2194 32.2785 6.98219 31.3291 6.91872 27.0253C6.91872 25 7.93431 22.0253 9.52117 20.443C11.5524 18.4177 14.0279 16.5823 17.8998 16.5823C21.6448 16.5823 22.6604 18.1646 22.9778 18.3544C23.2317 18.6076 23.2951 18.6709 23.4221 18.5443C23.549 18.481 22.7873 17.3418 22.47 16.8987C20.1849 13.2278 17.5824 10.6962 17.5824 7.34177C17.5824 4.24051 19.7406 1.58228 22.1526 1.58228C24.6916 1.4557 26.0245 2.91139 26.0245 3.79747L24.0568 7.97468C23.2951 10.1266 25.0089 11.4557 25.9611 11.8354C27.294 15.3165 31.1025 17.8481 31.2929 22.7848C31.4833 26.7722 28.3731 31.962 19.1058 32.5949L17.2651 32.7215L15.9956 33.4177L14.98 34.3038C14.98 34.8101 15.4878 37.2785 16.3764 37.3418L19.2962 37.4051C19.5501 37.4684 19.5501 38.1013 19.4867 38.6076ZM20.1214 36.2025L17.0112 36.1392C16.3764 35.5063 16.5668 34.4937 17.5824 34.2405L19.2328 34.0506L20.1214 36.2025ZM20.8196 33.9873L22.2161 33.6076L23.549 37.4684H26.7228C27.3575 37.4684 27.6749 38.1646 27.6749 38.6076H20.8831C20.4388 37.8481 20.8196 37.4684 20.8196 37.4684L21.8987 37.4051C21.9622 37.0253 21.2005 34.6835 20.6292 33.9873H20.8196Z' fill='%23181919'/%3E%3Cpath d='M27.3001 4C27.182 4.8125 26 7.375 26 7.375L27.7138 7.8125C29.1322 8 30.3732 8.0625 31.2597 8.5C32.6189 9.125 34.3328 10.625 35.0419 12C35.7511 11.6875 36.6967 7.8125 35.2192 5.75C34.0373 4.125 32.6189 4 31.3188 4H27.3001Z' fill='%23FDC60B'/%3E%3Cpath d='M31 5.03275C32.6432 5.63385 35.2066 7.01637 35.9954 9C36.1268 6.53549 33.432 4.7322 31 5.03275Z' fill='%23F7D872'/%3E%3Cpath d='M25.0984 9L29.5351 9.72943C30.7324 9.99468 31.9296 10.5915 32 10.7904C32 10.7904 28.6901 11.0557 27.1407 10.9894C25.6618 10.923 24.6759 9.92837 25.0984 9Z' fill='%23F8D10E'/%3E%3Cpath d='M22.9217 4C23.4069 4 23.9461 4.48649 24 5.37838C24 6.18919 23.5687 7 22.9217 7C22.3286 7 21.9512 6.10811 22.0051 5.21622C22.0051 4.48649 22.4364 4 22.9217 4Z' fill='%23171819'/%3E%3Cpath d='M11.1321 24.0169C11.5637 23.8447 12.1187 25.05 14.462 24.9639C15.2637 24.9639 15.3254 24.7056 15.8187 24.6195C16.312 24.6195 15.8187 25.997 14.092 25.997C11.8104 26.0831 10.5771 24.2751 11.1321 24.0169Z' fill='%23171819'/%3E%3C/svg%3E"
          />
        <% end %>
        <link rel="icon" type="image/png" sizes="32x32" href={~p"/favicon-32.png"} />
        <link rel="icon" type="image/png" sizes="16x16" href={~p"/favicon-16.png"} />
        <link rel="apple-touch-icon" sizes="180x180" href={~p"/apple-touch-icon.png"} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;700&display=swap"
          rel="stylesheet"
        />
        <%!-- Stylesheet only. Deliberately no app.js: this page is a form, and
              pulling in the LiveView client would open a socket for a LiveView
              that does not exist. --%>
        <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body class="bg-base-200/40">
        <main class="mx-auto flex min-h-screen max-w-lg flex-col justify-center px-6 py-12">
          <a href={~p"/"} class="logo-svg mb-6 flex items-center justify-center gap-2">
            <svg class="h-8 w-auto" viewBox="0 0 38 40" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path
                d="M32.4355 3.10127C31.2294 2.97468 28.8809 3.03797 27.3575 3.10127C26.9132 1.89873 25.2628 0 22.343 0C18.9154 0 15.8686 2.40506 15.8686 7.08861C15.8686 10.6962 17.8363 13.1013 19.1058 15.2532C17.2651 14.8734 11.6793 14.6203 7.48999 20C6.4744 18.2911 5.33186 17.4051 3.87194 17.4051C2.03118 17.4051 0.761694 19.1772 1.90423 21.3924C0.952117 21.3924 0 22.0886 0 23.6709C0 24.6835 0.507796 25.5063 1.45991 26.0759C1.01559 26.7089 0.888643 29.6203 4.06237 29.6203C4.57016 29.6203 5.33186 29.4304 5.64923 29.3038C6.60135 32.3418 9.14033 33.5443 11.3619 34.1772L11.9332 36.2658C11.1715 36.5823 10.4098 37.1519 10.4098 38.1013L10.4733 39.8101L29.1348 40C29.5156 38.1013 28.7539 36.3291 27.1036 36.2658L24.755 36.2025L23.676 33.3544C26.088 32.6582 33.0702 30.6962 33.0702 23.2911C33.0702 17.7848 29.1983 15.3165 27.7383 12.1519C29.0078 11.962 30.9121 11.7722 32.1181 11.7089C33.1972 11.7089 34.1493 12.4051 34.2762 13.9873C34.3397 14.6203 37.4499 14.3038 37.9577 10.1266C38.3386 6.77215 36.117 3.41772 32.4355 3.10127ZM19.4867 38.6076H11.9967C11.8697 37.6582 13.7105 37.8481 13.774 37.3418C13.8374 36.8987 13.0123 35.1266 12.9488 34.557L13.7105 33.9873C13.9009 33.7342 13.9009 33.2278 12.441 32.9747C10.2194 32.2785 6.98219 31.3291 6.91872 27.0253C6.91872 25 7.93431 22.0253 9.52117 20.443C11.5524 18.4177 14.0279 16.5823 17.8998 16.5823C21.6448 16.5823 22.6604 18.1646 22.9778 18.3544C23.2317 18.6076 23.2951 18.6709 23.4221 18.5443C23.549 18.481 22.7873 17.3418 22.47 16.8987C20.1849 13.2278 17.5824 10.6962 17.5824 7.34177C17.5824 4.24051 19.7406 1.58228 22.1526 1.58228C24.6916 1.4557 26.0245 2.91139 26.0245 3.79747L24.0568 7.97468C23.2951 10.1266 25.0089 11.4557 25.9611 11.8354C27.294 15.3165 31.1025 17.8481 31.2929 22.7848C31.4833 26.7722 28.3731 31.962 19.1058 32.5949L17.2651 32.7215L15.9956 33.4177L14.98 34.3038C14.98 34.8101 15.4878 37.2785 16.3764 37.3418L19.2962 37.4051C19.5501 37.4684 19.5501 38.1013 19.4867 38.6076ZM20.1214 36.2025L17.0112 36.1392C16.3764 35.5063 16.5668 34.4937 17.5824 34.2405L19.2328 34.0506L20.1214 36.2025ZM20.8196 33.9873L22.2161 33.6076L23.549 37.4684H26.7228C27.3575 37.4684 27.6749 38.1646 27.6749 38.6076H20.8831C20.4388 37.8481 20.8196 37.4684 20.8196 37.4684L21.8987 37.4051C21.9622 37.0253 21.2005 34.6835 20.6292 33.9873H20.8196Z"
                fill="#181919"
              />
              <path
                d="M27.3001 4C27.182 4.8125 26 7.375 26 7.375L27.7138 7.8125C29.1322 8 30.3732 8.0625 31.2597 8.5C32.6189 9.125 34.3328 10.625 35.0419 12C35.7511 11.6875 36.6967 7.8125 35.2192 5.75C34.0373 4.125 32.6189 4 31.3188 4H27.3001Z"
                fill="#FDC60B"
              />
              <path
                d="M31 5.03275C32.6432 5.63385 35.2066 7.01637 35.9954 9C36.1268 6.53549 33.432 4.7322 31 5.03275Z"
                fill="#F7D872"
              />
              <path
                d="M25.0984 9L29.5351 9.72943C30.7324 9.99468 31.9296 10.5915 32 10.7904C32 10.7904 28.6901 11.0557 27.1407 10.9894C25.6618 10.923 24.6759 9.92837 25.0984 9Z"
                fill="#F8D10E"
              />
              <path
                d="M22.9217 4C23.4069 4 23.9461 4.48649 24 5.37838C24 6.18919 23.5687 7 22.9217 7C22.3286 7 21.9512 6.10811 22.0051 5.21622C22.0051 4.48649 22.4364 4 22.9217 4Z"
                fill="#171819"
              />
              <path
                d="M11.1321 24.0169C11.5637 23.8447 12.1187 25.05 14.462 24.9639C15.2637 24.9639 15.3254 24.7056 15.8187 24.6195C16.312 24.6195 15.8187 25.997 14.092 25.997C11.8104 26.0831 10.5771 24.2751 11.1321 24.0169Z"
                fill="#171819"
              />
              <path
                d="M9.85879 26.0413C10.7545 25.4547 10.3706 26.8624 10.3067 26.921C9.98675 28.7393 13.3777 28.7979 16.3209 27.9768C19.2 27.2143 22.527 25.2788 22.527 22.2288L22.3991 20.4692L22.9109 20C23.8706 20.176 25.2142 23.9884 21.8232 26.8624C18.6882 29.6777 12.2901 31.0268 9.79481 29.0912C8.51519 27.9181 8.96306 26.5105 9.85879 26.0413Z"
                fill="#171819"
              />
              <path
                d="M2.98037 21.5604L4.05706 22.235L3.98528 22.6643C3.48282 22.7257 2.98037 22.3577 2.47792 22.4803C1.54479 22.5417 0.68344 23.2163 1.11411 24.1362C1.61657 25.2402 3.33927 25.3015 3.9135 25.3628V25.6695L2.69325 26.2214C1.68835 26.5894 2.04724 28 3.69816 28C5.06196 28 5.42086 27.632 5.42086 27.632C5.20552 25.3015 6.06687 23.2163 7 21.1924C6.56933 20.0272 5.13374 18.7392 3.69816 19.0459C2.62148 19.3525 1.97546 20.7018 2.98037 21.5604Z"
                fill="#171819"
              />
            </svg>
            <span class="text-xl tracking-tight" style="font-family: 'Poppins', sans-serif;">
              <span class="font-semibold">Dodo</span><span class="font-semibold text-[#FCC309]">Router</span>
            </span>
          </a>
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

            <p class="mt-6 text-[11px] font-semibold uppercase tracking-wider text-base-content/40">
              Access to your data
            </p>
            <div class="mt-1.5 space-y-2">
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
                No access to your data requested.
              </p>
            </div>

            <div :if={@session_scopes != []} class="mt-4 border-t border-base-300/60 pt-3">
              <p class="text-[11px] font-semibold uppercase tracking-wider text-base-content/40">
                Sign-in
              </p>
              <label
                :for={scope <- @session_scopes}
                class="mt-1.5 flex cursor-pointer items-center gap-2.5 text-xs text-base-content/55"
              >
                <input
                  type="checkbox"
                  name="granted_scopes[]"
                  value={scope.name}
                  checked
                  form="consent-approve"
                  class="size-3.5 rounded border-base-300"
                />
                <span>{scope.description}</span>
              </label>
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
