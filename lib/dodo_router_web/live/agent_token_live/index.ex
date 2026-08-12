defmodule DodoRouterWeb.AgentTokenLive.Index do
  @moduledoc """
  Mint, scope and revoke agent tokens, and read what they did.

  The credential list and the audit trail live on one page on purpose. A token
  is only as trustworthy as your ability to see what it has been doing, and
  splitting them across two screens means nobody looks at the second one.
  """

  use DodoRouterWeb, :live_view

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Scopes
  alias DodoRouter.Routers

  @expiry_options [
    {"30 days", "30"},
    {"90 days", "90"},
    {"1 year", "365"},
    {"Never expires", "never"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent tokens")
     |> assign(:base_url, DodoRouterWeb.Endpoint.url())
     |> assign(:new_secret, nil)
     |> assign(:revoking_id, nil)
     |> assign(:form, blank_form())
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user
    tokens = Agents.list_tokens(user)

    socket
    |> assign(:routers, Routers.list_routers(user))
    |> assign(:tokens, tokens)
    |> assign(:reach, Map.new(tokens, &{&1.id, Agents.routers_for(user, &1)}))
    |> assign(:stats, Map.new(tokens, &{&1.id, Agents.call_stats(user, agent_token_id: &1.id)}))
    |> assign(:calls, Agents.list_calls(user, limit: 25))
    |> assign(:totals, Agents.call_stats(user))
  end

  # A params form rather than a changeset form: `create_changeset/2` mints a
  # secret every time it runs, and driving live validation through it would
  # generate a throwaway credential on every keystroke.
  defp blank_form do
    to_form(
      %{
        "name" => "",
        "scopes" => Scopes.defaults(),
        "expires_in_days" => "90",
        "reach" => "selected",
        "router_ids" => []
      },
      as: :token
    )
  end

  @impl true
  def handle_event("validate", %{"token" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :token))}
  end

  def handle_event("create", %{"token" => params}, socket) do
    attrs = %{
      "name" => params["name"],
      "scopes" => params["scopes"] || [],
      "expires_at" => expires_at(params["expires_in_days"]),
      "all_routers" => params["reach"] == "all",
      "router_ids" => if(params["reach"] == "all", do: [], else: params["router_ids"] || [])
    }

    case Agents.create_token(socket.assigns.current_user, attrs) do
      {:ok, token} ->
        # The example command needs a concrete router, so resolve one this
        # token can actually reach rather than printing a placeholder.
        example_slug =
          socket.assigns.current_user
          |> Agents.routers_for(token)
          |> List.first()
          |> then(&(&1 && &1.slug))

        {:noreply,
         socket
         |> assign(:new_secret, %{name: token.name, value: token.token, slug: example_slug})
         |> assign(:form, blank_form())
         |> load()
         |> put_flash(:info, "Minted “#{token.name}”. Copy it now — it is not stored.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :token, errors: form_errors(changeset)))
         |> put_flash(:error, "Could not mint that token.")}
    end
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, :new_secret, nil)}

  def handle_event("confirm_revoke", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :revoking_id, id)}

  def handle_event("cancel_revoke", _params, socket),
    do: {:noreply, assign(socket, :revoking_id, nil)}

  def handle_event("revoke", %{"id" => id}, socket) do
    case Agents.revoke_token(socket.assigns.current_user, id) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(:revoking_id, nil)
         |> load()
         |> put_flash(:info, "Revoked “#{token.name}”. Its history is kept.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such token.")}
    end
  end

  defp expires_at("never"), do: nil

  defp expires_at(days) do
    DateTime.utc_now()
    |> DateTime.add(String.to_integer(days) * 24 * 3600, :second)
    |> DateTime.truncate(:second)
  end

  defp form_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, opts}} -> {field, {message, opts}} end)
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl space-y-8">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">Agent access</p>
          <h1 class="text-3xl font-semibold tracking-tight">Agent tokens</h1>
          <p class="mt-1 max-w-2xl text-base-content/55">
            Credentials for coding agents that read your traffic and run evaluations. Separate
            from a router's proxy key on purpose — that one sends traffic, these read it back.
          </p>
        </div>

        <.secret_banner :if={@new_secret} secret={@new_secret} base_url={@base_url} />

        <.mint_form form={@form} routers={@routers} expiry_options={expiry_options()} />

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Your tokens</h2>

          <p
            :if={@tokens == []}
            class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-base-content/50"
          >
            No agent tokens yet. Mint one above to let an agent reach your routers.
          </p>

          <.token_row
            :for={token <- @tokens}
            token={token}
            reach={Map.get(@reach, token.id, [])}
            stats={Map.get(@stats, token.id, %{})}
            revoking?={@revoking_id == token.id}
          />
        </section>

        <.audit_trail calls={@calls} totals={@totals} />
      </div>
    </Layouts.app>
    """
  end

  defp secret_banner(assigns) do
    ~H"""
    <div id="new-token-secret" class="rounded-2xl border border-accent/30 bg-accent/5 p-5">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <p class="text-sm font-semibold text-accent">“{@secret.name}” is ready</p>
          <p class="mt-1 text-xs text-base-content/55">
            This is the only time it exists — DodoRouter stores a hash, not the token.
          </p>

          <div class="mt-3 flex items-center gap-2">
            <code class="min-w-0 flex-1 overflow-x-auto rounded-lg border border-base-300/50 bg-base-100 px-3 py-2 font-mono text-sm">
              {@secret.value}
            </code>
            <button
              id="copy-agent-token"
              phx-hook="CopyButton"
              data-copy={@secret.value}
              class="rounded-lg border border-base-300/50 bg-base-100 p-2 transition-colors hover:bg-secondary"
              title="Copy token"
            >
              <.icon name="hero-clipboard" class="size-4 text-base-content/60" />
            </button>
          </div>

          <%!--
            The command shown is the one that works today. An MCP endpoint is
            coming, but printing `claude mcp add ... /mcp` before it exists
            would hand someone a command that 404s.
          --%>
          <p :if={@secret.slug} class="mt-3 text-xs text-base-content/45">
            Point an agent at it — this returns the whole workflow:
          </p>
          <code
            :if={@secret.slug}
            class="mt-1 block overflow-x-auto rounded-lg bg-base-200/70 px-3 py-2 font-mono text-xs"
          >
            curl -H "Authorization: Bearer {@secret.value}" {@base_url}/r/{@secret.slug}/agent
          </code>
          <p :if={!@secret.slug} class="mt-3 text-xs text-base-content/45">
            This token reaches no router yet, so there is nothing to call. Create a router first.
          </p>
        </div>

        <button
          phx-click="dismiss_secret"
          class="rounded p-1 text-base-content/40 transition-colors hover:bg-base-200 hover:text-base-content"
          title="Dismiss"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp mint_form(assigns) do
    ~H"""
    <section class="rounded-2xl border border-base-300/60 bg-base-100 p-5">
      <h2 class="text-lg font-semibold">Mint a token</h2>

      <.form
        for={@form}
        id="mint-token-form"
        phx-change="validate"
        phx-submit="create"
        class="mt-4 space-y-6"
      >
        <.input field={@form[:name]} type="text" label="Name" placeholder="Claude Code on my laptop" />
        <p class="-mt-4 text-xs text-base-content/45">
          Audit rows are labelled with this, so name it after the agent that holds it.
        </p>

        <fieldset>
          <legend class="text-sm font-medium">Permissions</legend>
          <.field_errors field={@form[:scopes]} />
          <div class="mt-2 space-y-2">
            <label
              :for={scope <- Scopes.all()}
              class={[
                "flex cursor-pointer items-start gap-3 rounded-xl border p-3 transition-colors",
                scope.sensitive? && "border-warning/30 bg-warning/5 hover:border-warning/50",
                !scope.sensitive? && "border-base-300/60 hover:border-primary/40"
              ]}
            >
              <input
                type="checkbox"
                name="token[scopes][]"
                value={scope.name}
                checked={scope.name in (@form[:scopes].value || [])}
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
          </div>
        </fieldset>

        <fieldset>
          <legend class="text-sm font-medium">Routers it can reach</legend>
          <p class="mt-1 text-xs text-base-content/45">
            One app is usually several routers. A token covers as many as you pick.
          </p>
          <.field_errors field={@form[:router_ids]} />

          <div class="mt-2 space-y-2">
            <label class="flex cursor-pointer items-start gap-3 rounded-xl border border-base-300/60 p-3 hover:border-primary/40">
              <input
                type="radio"
                name="token[reach]"
                value="selected"
                checked={@form[:reach].value != "all"}
                class="mt-0.5 size-4"
              />
              <span>
                <span class="text-sm font-medium">These routers</span>
                <span class="mt-0.5 block text-xs text-base-content/55">
                  Routers added later are not included.
                </span>
              </span>
            </label>

            <div :if={@form[:reach].value != "all"} class="ml-7 space-y-1.5">
              <label
                :for={router <- @routers}
                class="flex cursor-pointer items-center gap-2.5 rounded-lg px-2 py-1.5 text-sm hover:bg-base-200/60"
              >
                <input
                  type="checkbox"
                  name="token[router_ids][]"
                  value={router.id}
                  checked={router.id in (@form[:router_ids].value || [])}
                  class="size-4 rounded border-base-300"
                />
                <span>{router.name}</span>
                <code class="font-mono text-[11px] text-base-content/35">{router.slug}</code>
              </label>

              <p :if={@routers == []} class="px-2 py-1.5 text-xs text-base-content/45">
                No routers yet — create one first.
              </p>
            </div>

            <label class="flex cursor-pointer items-start gap-3 rounded-xl border border-warning/30 bg-warning/5 p-3 hover:border-warning/50">
              <input
                type="radio"
                name="token[reach]"
                value="all"
                checked={@form[:reach].value == "all"}
                class="mt-0.5 size-4"
              />
              <span>
                <span class="text-sm font-medium">Every router on this account</span>
                <span class="mt-0.5 block text-xs text-base-content/55">
                  Including routers you create later, and routers belonging to your other apps.
                </span>
              </span>
            </label>
          </div>
        </fieldset>

        <div class="max-w-xs">
          <.input
            field={@form[:expires_in_days]}
            type="select"
            label="Expires"
            options={@expiry_options}
          />
        </div>

        <button
          id="mint-token-button"
          type="submit"
          class="rounded-xl bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-90"
        >
          Mint token
        </button>
      </.form>
    </section>
    """
  end

  # `<.input>` renders its own errors; these two fieldsets are hand-rolled
  # checkbox groups, so without this their validation failures reach the flash
  # and nowhere else — the user is told "could not mint" next to a form that
  # looks fine.
  defp field_errors(assigns) do
    ~H"""
    <p :for={{message, _opts} <- @field.errors} class="mt-1 text-xs text-error">
      {message}
    </p>
    """
  end

  defp token_row(assigns) do
    ~H"""
    <div
      id={"token-#{@token.id}"}
      class={[
        "rounded-2xl border bg-base-100 p-4",
        @token.revoked_at && "border-base-300/40 opacity-60",
        !@token.revoked_at && "border-base-300/60"
      ]}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-semibold">{@token.name}</span>
            <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[11px] text-base-content/50">
              {@token.token_prefix}…
            </code>
            <.status_pill token={@token} />
          </div>

          <div class="mt-2 flex flex-wrap gap-1.5">
            <span
              :for={scope <- @token.scopes}
              class={[
                "rounded-full px-2 py-0.5 font-mono text-[11px]",
                Scopes.sensitive?(scope) && "bg-warning/15 text-warning",
                !Scopes.sensitive?(scope) && "bg-base-200 text-base-content/60"
              ]}
            >
              {scope}
            </span>
          </div>

          <p class="mt-2 text-xs text-base-content/55">
            <%= if @token.all_routers do %>
              Every router — currently {length(@reach)}, and any created later
            <% else %>
              {reach_label(@reach)}
            <% end %>
          </p>
        </div>

        <div class="flex items-center gap-4 text-right">
          <div class="text-xs text-base-content/50">
            <p>{used_label(@token.last_used_at)}</p>
            <p>{expiry_label(@token)}</p>
          </div>

          <div :if={denied_count(@stats) > 0} class="rounded-lg bg-error/10 px-2.5 py-1.5 text-center">
            <p class="text-sm font-semibold text-error">{denied_count(@stats)}</p>
            <p class="text-[10px] uppercase tracking-wide text-error/70">denied</p>
          </div>

          <div :if={!@token.revoked_at && !@revoking?}>
            <button
              phx-click="confirm_revoke"
              phx-value-id={@token.id}
              class="rounded-lg border border-base-300/60 px-3 py-1.5 text-xs font-medium transition hover:border-error/40 hover:text-error"
            >
              Revoke
            </button>
          </div>

          <div :if={@revoking?} class="flex items-center gap-2">
            <span class="text-xs text-base-content/55">Stops working immediately.</span>
            <button
              phx-click="revoke"
              phx-value-id={@token.id}
              class="rounded-lg bg-error px-3 py-1.5 text-xs font-semibold text-error-content"
            >
              Revoke
            </button>
            <button
              phx-click="cancel_revoke"
              class="rounded-lg border border-base-300/60 px-3 py-1.5 text-xs"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_pill(assigns) do
    ~H"""
    <span
      :if={@token.revoked_at}
      class="rounded-full bg-base-300/60 px-2 py-0.5 text-[11px] font-medium"
    >
      Revoked
    </span>
    <span
      :if={!@token.revoked_at && expired?(@token)}
      class="rounded-full bg-base-300/60 px-2 py-0.5 text-[11px] font-medium"
    >
      Expired
    </span>
    """
  end

  defp audit_trail(assigns) do
    ~H"""
    <section class="space-y-3">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-semibold">What agents did</h2>
        <p class="text-xs text-base-content/50">
          {Map.get(@totals, "ok", 0)} allowed · {Map.get(@totals, "denied", 0)} denied · {Map.get(
            @totals,
            "error",
            0
          )} errored
        </p>
      </div>

      <div class="overflow-hidden rounded-2xl border border-base-300/60 bg-base-100">
        <p :if={@calls == []} class="p-10 text-center text-base-content/50">
          Nothing yet. Calls appear here the moment an agent uses a token.
        </p>

        <table :if={@calls != []} class="w-full text-sm">
          <thead class="border-b border-base-300/60 text-left text-xs uppercase tracking-wide text-base-content/45">
            <tr>
              <th class="px-4 py-2 font-medium">When</th>
              <th class="px-4 py-2 font-medium">Token</th>
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

  ## Labels

  defp expiry_options, do: @expiry_options

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp reach_label([]), do: "No routers — this token cannot reach anything"
  defp reach_label([router]), do: router.name
  defp reach_label(routers), do: Enum.map_join(routers, ", ", & &1.name)

  defp used_label(nil), do: "Never used"
  defp used_label(at), do: "Last used #{Calendar.strftime(at, "%b %d")}"

  defp expiry_label(%{revoked_at: %DateTime{} = at}),
    do: "Revoked #{Calendar.strftime(at, "%b %d")}"

  defp expiry_label(%{expires_at: nil}), do: "No expiry"
  defp expiry_label(%{expires_at: at}), do: "Expires #{Calendar.strftime(at, "%b %d, %Y")}"

  defp denied_count(stats), do: Map.get(stats, "denied", 0)
end
