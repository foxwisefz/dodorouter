defmodule DodoRouterWeb.LogLive.Replay do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Replays
  alias DodoRouter.TextDiff

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    log =
      case Logs.get_log(socket.assigns.current_user, id) do
        nil -> Logs.get_log_by_request_id!(socket.assigns.current_user, id)
        log -> log
      end

    targets = Replays.list_targets(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Replay #{String.slice(log.request_id, 0, 8)}...")
      |> assign(:source, log)
      |> assign(:source_msg, MessageNormalizer.parse_response_body(log.response_body))
      |> assign(:blocker, Replays.replay_blocker(log))
      |> assign(:targets, targets)
      |> assign(
        :target_form,
        to_form(%{"provider_key_id" => default_key_id(targets), "model" => ""}, as: :replay)
      )
      |> assign(:replays, Logs.list_replays(log))
      |> assign(:running?, false)
      |> assign(:diff_view, "diff")
      |> assign(:selected, nil)
      |> assign(:diff, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    replays = socket.assigns.replays

    selected =
      Enum.find(replays, &(&1.id == params["replay"])) || List.last(replays)

    {:noreply, select_replay(socket, selected)}
  end

  @impl true
  def handle_event("validate_target", %{"replay" => params}, socket) do
    {:noreply, assign(socket, :target_form, to_form(params, as: :replay))}
  end

  def handle_event("run_replay", %{"replay" => params}, socket) do
    %{current_user: user, source: source} = socket.assigns

    target = %{
      provider_key_id: params["provider_key_id"],
      model: String.trim(params["model"] || "")
    }

    socket =
      socket
      |> assign(:running?, true)
      |> start_async(:run_replay, fn -> Replays.replay(user, source, target) end)

    {:noreply, socket}
  end

  def handle_event("set_diff_view", %{"view" => view}, socket)
      when view in ~w(diff side raw) do
    {:noreply, assign(socket, :diff_view, view)}
  end

  @impl true
  def handle_async(:run_replay, {:ok, {:ok, replay_log}}, socket) do
    socket =
      socket
      |> assign(:running?, false)
      |> assign(:replays, Logs.list_replays(socket.assigns.source))
      |> push_patch(to: ~p"/logs/#{socket.assigns.source.id}/replay?replay=#{replay_log.id}")

    {:noreply, socket}
  end

  def handle_async(:run_replay, {:ok, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:running?, false)
      |> put_flash(:error, replay_error_message(reason))

    {:noreply, socket}
  end

  def handle_async(:run_replay, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(:running?, false)
      |> put_flash(:error, "Replay failed unexpectedly: #{inspect(reason)}")

    {:noreply, socket}
  end

  def handle_async(:compute_diff, {:ok, diff}, socket) do
    {:noreply, assign(socket, :diff, diff)}
  end

  def handle_async(:compute_diff, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket, :diff, %{content: TextDiff.diff("", ""), reasoning: nil, tool_args: nil})}
  end

  defp select_replay(socket, nil) do
    socket |> assign(:selected, nil) |> assign(:diff, nil) |> assign(:deltas, [])
  end

  defp select_replay(socket, replay_log) do
    source_msg = socket.assigns.source_msg
    replay_msg = MessageNormalizer.parse_response_body(replay_log.response_body)

    socket =
      socket
      |> assign(:selected, replay_log)
      |> assign(:replay_msg, replay_msg)
      |> assign(:deltas, Replays.deltas(socket.assigns.source, replay_log))
      |> assign(:diff, nil)

    if replay_log.status == "error" do
      socket
    else
      orig_text = message_text(source_msg)
      repl_text = message_text(replay_msg)
      orig_reasoning = message_reasoning(source_msg)
      repl_reasoning = message_reasoning(replay_msg)
      orig_args = single_tool_args(source_msg)
      repl_args = single_tool_args(replay_msg)

      start_async(socket, :compute_diff, fn ->
        %{
          content: TextDiff.diff(orig_text, repl_text),
          reasoning:
            if(orig_reasoning || repl_reasoning,
              do: TextDiff.diff(orig_reasoning, repl_reasoning)
            ),
          tool_args: if(orig_args && repl_args, do: TextDiff.diff(orig_args, repl_args))
        }
      end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex items-center gap-4 mb-6">
        <.link navigate={~p"/logs/#{@source.id}"} class="btn btn-ghost btn-sm btn-square">
          <.icon name="hero-arrow-left" class="w-5 h-5" />
        </.link>
        <div class="flex-1">
          <h1 class="text-2xl font-bold">Replay &amp; Compare</h1>
          <code class="text-sm text-base-content/60">{@source.request_id}</code>
        </div>
        <.link
          :if={@source.replayed_from_id}
          navigate={~p"/logs/#{@source.replayed_from_id}/replay?replay=#{@source.id}"}
          class="badge badge-ghost gap-1"
          id="source-is-replay-link"
        >
          <.icon name="hero-arrow-uturn-left" class="w-3 h-3" /> this log is itself a replay
        </.link>
      </div>
      
    <!-- Blocker -->
      <div
        :if={@blocker}
        id="replay-blocker"
        class="card-bordered mb-6 flex items-start gap-3 border-warning/40 bg-warning/5"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-warning shrink-0 mt-0.5" />
        <div>
          <p class="font-medium text-base-content">This request can't be replayed</p>
          <p class="text-sm text-base-content/60">{blocker_message(@blocker)}</p>
        </div>
      </div>
      
    <!-- Target picker -->
      <div :if={!@blocker} class="card-bordered mb-6">
        <div class="flex items-center justify-between mb-3">
          <div>
            <h2 class="section-title">Run against another model</h2>
            <p class="section-desc">
              Originally answered by
              <span class="font-medium text-base-content">
                {@source.final_provider} / {@source.final_model}
              </span>
            </p>
          </div>
        </div>

        <.form
          for={@target_form}
          id="replay-form"
          phx-change="validate_target"
          phx-submit="run_replay"
          class="flex flex-col sm:flex-row sm:items-end gap-3"
        >
          <div class="w-full sm:w-64">
            <label class="text-xs font-medium text-base-content/50 block mb-1">Provider key</label>
            <select
              name={@target_form[:provider_key_id].name}
              id="replay-provider-key"
              class="select select-sm w-full"
            >
              {Phoenix.HTML.Form.options_for_select(
                target_options(@targets),
                @target_form[:provider_key_id].value
              )}
            </select>
          </div>

          <div class="w-full sm:flex-1">
            <label class="text-xs font-medium text-base-content/50 block mb-1">Model</label>
            <input
              type="text"
              name={@target_form[:model].name}
              id="replay-model"
              value={@target_form[:model].value}
              list="replay-model-options"
              placeholder="Pick a model or type any model id…"
              autocomplete="off"
              class="input input-sm w-full"
            />
            <datalist id="replay-model-options">
              <option
                :for={model <- selected_target_models(@targets, @target_form[:provider_key_id].value)}
                value={model.id}
              >
                {model_option_label(model)}
              </option>
            </datalist>
            <p class="text-xs text-base-content/40 mt-1 h-4" id="replay-price-hint">
              {price_hint(@targets, @target_form[:provider_key_id].value, @target_form[:model].value)}
            </p>
          </div>

          <button
            type="submit"
            id="run-replay-button"
            class="btn btn-primary btn-sm gap-2"
            disabled={@running? or @target_form[:model].value in [nil, ""]}
          >
            <span :if={@running?} class="loading loading-spinner loading-xs"></span>
            <.icon :if={!@running?} name="hero-arrow-path" class="w-4 h-4" />
            {if @running?, do: "Running…", else: "Run replay"}
          </button>
        </.form>
        <p :if={@running?} class="text-xs text-base-content/40 mt-2 animate-pulse">
          Dispatching to the provider — long generations can take up to a minute.
        </p>
      </div>
      
    <!-- Replay switcher -->
      <div :if={@replays != []} class="flex items-center gap-2 mb-4 flex-wrap" id="replay-switcher">
        <span class="text-xs font-medium text-base-content/50">Replays:</span>
        <.link
          :for={{r, idx} <- Enum.with_index(@replays, 1)}
          patch={~p"/logs/#{@source.id}/replay?replay=#{r.id}"}
          class={[
            "badge gap-1.5 transition-colors",
            @selected && @selected.id == r.id && "badge-primary",
            !(@selected && @selected.id == r.id) && "badge-ghost hover:badge-secondary"
          ]}
          id={"replay-chip-#{idx}"}
        >
          <span class={["w-1.5 h-1.5 rounded-full", replay_dot(r.status)]}></span>
          {r.final_model || "unknown"}
        </.link>
      </div>
      
    <!-- Empty state -->
      <div
        :if={@selected == nil and !@running? and !@blocker}
        class="empty-state card-bordered py-16 text-center"
        id="replay-empty-state"
      >
        <.icon name="hero-scale" class="w-8 h-8 mx-auto text-base-content/20 mb-3" />
        <p class="font-medium text-base-content/70">No replays yet</p>
        <p class="text-sm text-base-content/40 mt-1">
          Pick a model above and run a replay — the two responses will be compared side by side here.
        </p>
      </div>
      
    <!-- Running skeleton (first run) -->
      <div
        :if={@selected == nil and @running?}
        class="card-bordered py-12"
        id="replay-running-skeleton"
      >
        <div class="max-w-md mx-auto space-y-3 animate-pulse">
          <div class="h-3 bg-base-300/60 rounded w-3/4"></div>
          <div class="h-3 bg-base-300/60 rounded w-full"></div>
          <div class="h-3 bg-base-300/60 rounded w-5/6"></div>
        </div>
      </div>

      <%= if @selected do %>
        <!-- Identity band -->
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4" id="compare-identity">
          <.identity_card id="compare-original" label="Original" log={@source} />
          <.identity_card id="compare-replay" label="Replay" log={@selected} />
        </div>
        
    <!-- Delta strip -->
        <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-7 gap-3 mb-6" id="delta-strip">
          <div
            :for={delta <- @deltas}
            class="rounded-lg border border-base-300/50 bg-base-100 p-3"
            id={"delta-#{delta.key}"}
          >
            <div class="text-xs font-medium text-base-content/50">{delta.label}</div>
            <div class="text-sm font-semibold text-base-content mt-1 truncate">
              {format_metric(delta.key, delta.original)}
              <span class="text-base-content/30 font-normal">→</span>
              {format_metric(delta.key, delta.replay)}
            </div>
            <div class={["text-xs mt-1 font-medium", delta_color(delta.direction)]}>
              {delta_chip(delta)}
            </div>
          </div>
        </div>
        
    <!-- View tabs -->
        <div class="flex items-center gap-1 mb-3" id="diff-view-tabs">
          <button
            :for={{view, label} <- [{"diff", "Diff"}, {"side", "Side by side"}, {"raw", "Raw JSON"}]}
            type="button"
            phx-click="set_diff_view"
            phx-value-view={view}
            id={"diff-view-#{view}"}
            class={[
              "btn btn-xs",
              @diff_view == view && "btn-primary",
              @diff_view != view && "btn-ghost"
            ]}
          >
            {label}
          </button>
          <span
            :if={@diff && @diff.content.granularity != :none}
            class="text-xs text-base-content/40 ml-2"
          >
            {diff_stats_caption(@diff.content)}
          </span>
        </div>
        
    <!-- Failed replay -->
        <div
          :if={@selected.status == "error"}
          class="card-bordered border-error/30"
          id="replay-error-panel"
        >
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-x-circle" class="w-5 h-5 text-error" />
            <span class="font-medium">The replay failed — nothing to compare</span>
          </div>
          <pre class="mockup-code text-xs overflow-x-auto p-4"><code>{format_json(@selected.response_body)}</code></pre>
        </div>

        <%= if @selected.status != "error" do %>
          <!-- Diff view -->
          <div :if={@diff_view == "diff"} id="compare-diff-pane">
            <div :if={@diff == nil} class="card-bordered py-10" id="diff-loading">
              <div class="max-w-lg mx-auto space-y-3 animate-pulse">
                <div class="h-3 bg-base-300/60 rounded w-full"></div>
                <div class="h-3 bg-base-300/60 rounded w-4/5"></div>
              </div>
            </div>

            <%= if @diff do %>
              <div
                :if={@diff.content.granularity == :none and @diff.content.reason == :too_large}
                class="card-bordered mb-3 text-sm text-base-content/60"
                id="diff-too-large"
              >
                Responses are too large to diff inline — showing them side by side instead.
              </div>

              <div :if={@diff.content.granularity != :none} class="card-bordered" id="content-diff">
                <.diff_block segments={@diff.content.segments} />
              </div>

              <div :if={
                @diff.content.granularity == :none and @diff.content.reason in [:too_large, :empty]
              }>
                <.side_by_side
                  source_msg={@source_msg}
                  replay_msg={@replay_msg}
                  source={@source}
                  selected={@selected}
                />
              </div>

              <div
                :if={@diff.content.granularity == :none and @diff.content.reason == :one_sided}
                class="card-bordered"
                id="content-diff-one-sided"
              >
                <.diff_block segments={@diff.content.segments} />
              </div>

              <details :if={@diff.reasoning} class="card-bordered mt-3" id="reasoning-diff">
                <summary class="cursor-pointer text-sm font-medium text-base-content/70">
                  Reasoning diff
                </summary>
                <div class="mt-3">
                  <.diff_block
                    :if={@diff.reasoning.granularity != :none}
                    segments={@diff.reasoning.segments}
                  />
                  <p
                    :if={
                      @diff.reasoning.granularity == :none and @diff.reasoning.reason == :one_sided
                    }
                    class="text-sm text-base-content/50"
                  >
                    Only one side produced reasoning content.
                  </p>
                </div>
              </details>

              <.tool_calls_section
                source_msg={@source_msg}
                replay_msg={@replay_msg}
                tool_args_diff={@diff.tool_args}
              />
            <% end %>
          </div>
          
    <!-- Side by side view -->
          <div :if={@diff_view == "side"} id="compare-side-pane">
            <.side_by_side
              source_msg={@source_msg}
              replay_msg={@replay_msg}
              source={@source}
              selected={@selected}
            />
          </div>
        <% end %>
        
    <!-- Raw JSON view -->
        <div
          :if={@diff_view == "raw"}
          class="grid grid-cols-1 lg:grid-cols-2 gap-3"
          id="compare-raw-pane"
        >
          <div>
            <div class="text-xs font-medium text-base-content/50 mb-1">Original response</div>
            <pre class="mockup-code text-xs overflow-x-auto p-4"><code>{format_json(@source.response_body)}</code></pre>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/50 mb-1">Replay response</div>
            <pre class="mockup-code text-xs overflow-x-auto p-4"><code>{format_json(@selected.response_body)}</code></pre>
          </div>
        </div>
        
    <!-- Footer links -->
        <div class="flex items-center gap-4 mt-6 text-sm" id="compare-footer">
          <.link navigate={~p"/logs/#{@source.id}"} class="text-primary hover:underline">
            Original log ↗
          </.link>
          <.link navigate={~p"/logs/#{@selected.id}"} class="text-primary hover:underline">
            Replay log ↗
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Components ---

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :log, :map, required: true

  defp identity_card(assigns) do
    ~H"""
    <div class="card-bordered flex items-center gap-3" id={@id}>
      <div class="w-8 h-8 rounded-lg bg-base-200 flex items-center justify-center shrink-0">
        <.provider_logo slug={normalize_slug(@log.final_provider || "unknown")} class="w-5 h-5" />
      </div>
      <div class="min-w-0 flex-1">
        <div class="text-xs font-medium text-base-content/50">{@label}</div>
        <div class="font-semibold text-base-content truncate">{@log.final_model || "unknown"}</div>
        <div class="text-xs text-base-content/40">{@log.final_provider}</div>
      </div>
      <.status_badge status={@log.status} />
    </div>
    """
  end

  attr :segments, :list, required: true

  defp diff_block(assigns) do
    ~H"""
    <div class="whitespace-pre-wrap break-words text-sm leading-relaxed">
      <%= for {op, text} <- @segments do %>
        <%= case op do %>
          <% :eq -> %>
            <span>{text}</span>
          <% :del -> %>
            <del class="bg-error/15 text-error rounded-sm no-underline">{text}</del>
          <% :ins -> %>
            <ins class="bg-success/15 text-success rounded-sm no-underline">{text}</ins>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :source_msg, :map, default: nil
  attr :replay_msg, :map, default: nil
  attr :source, :map, required: true
  attr :selected, :map, required: true

  defp side_by_side(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
      <div class="card-bordered">
        <div class="text-xs font-medium text-base-content/50 mb-2">
          Original · {@source.final_model}
        </div>
        <div class="whitespace-pre-wrap break-words text-sm leading-relaxed">
          {message_text(@source_msg) || "No text content"}
        </div>
      </div>
      <div class="card-bordered">
        <div class="text-xs font-medium text-base-content/50 mb-2">
          Replay · {@selected.final_model}
        </div>
        <div class="whitespace-pre-wrap break-words text-sm leading-relaxed">
          {message_text(@replay_msg) || "No text content"}
        </div>
      </div>
    </div>
    """
  end

  attr :source_msg, :map, default: nil
  attr :replay_msg, :map, default: nil
  attr :tool_args_diff, :map, default: nil

  defp tool_calls_section(assigns) do
    ~H"""
    <div
      :if={tool_calls(@source_msg) != [] or tool_calls(@replay_msg) != []}
      class="mt-3"
      id="tool-calls-section"
    >
      <div class="text-xs font-medium text-base-content/50 mb-2">Tool calls</div>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <.tool_calls_card label="Original" calls={tool_calls(@source_msg)} />
        <.tool_calls_card label="Replay" calls={tool_calls(@replay_msg)} />
      </div>
      <div
        :if={@tool_args_diff && @tool_args_diff.granularity != :none}
        class="card-bordered mt-3"
        id="tool-args-diff"
      >
        <div class="text-xs font-medium text-base-content/50 mb-2">Arguments diff</div>
        <.diff_block segments={@tool_args_diff.segments} />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :calls, :list, required: true

  defp tool_calls_card(assigns) do
    ~H"""
    <div class="card-bordered">
      <div class="text-xs font-medium text-base-content/50 mb-2">{@label}</div>
      <p :if={@calls == []} class="text-sm text-base-content/40">No tool calls</p>
      <div :for={call <- @calls} class="mb-2 last:mb-0">
        <span class="badge badge-secondary badge-sm mb-1">{call["function"]["name"]}</span>
        <pre class="text-xs bg-base-200/50 rounded p-2 overflow-x-auto whitespace-pre-wrap">{pretty_args(call)}</pre>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "badge-success"
        "fallback" -> "badge-warning"
        "error" -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"badge #{@class}"}>{@status}</span>
    """
  end

  # --- Helpers ---

  defp default_key_id([%{provider_key: key} | _rest]), do: key.id
  defp default_key_id([]), do: nil

  defp target_options(targets) do
    Enum.map(targets, fn target ->
      label =
        case target.provider_key.label do
          nil -> target.display_name
          "" -> target.display_name
          key_label -> "#{target.display_name} · #{key_label}"
        end

      {label, target.provider_key.id}
    end)
  end

  defp selected_target(targets, provider_key_id) do
    Enum.find(targets, &(&1.provider_key.id == provider_key_id)) || List.first(targets)
  end

  defp selected_target_models(targets, provider_key_id) do
    case selected_target(targets, provider_key_id) do
      nil -> []
      target -> target.models
    end
  end

  defp model_option_label(%{display_name: name, input_price: nil}), do: name

  defp model_option_label(%{display_name: name, input_price: input, output_price: output}) do
    "#{name} — $#{input}/$#{output} per Mtok"
  end

  defp price_hint(targets, provider_key_id, model) when is_binary(model) and model != "" do
    models = selected_target_models(targets, provider_key_id)

    case Enum.find(models, &(&1.id == model)) do
      %{input_price: input, output_price: output} when not is_nil(input) ->
        "$#{input} in / $#{output} out per Mtok"

      %{} ->
        "No pricing data for this model"

      nil ->
        "Custom model id — pricing unknown"
    end
  end

  defp price_hint(_targets, _key_id, _model), do: ""

  defp replay_dot("success"), do: "bg-success"
  defp replay_dot("fallback"), do: "bg-warning"
  defp replay_dot(_status), do: "bg-error"

  defp message_text(nil), do: nil

  defp message_text(%{content: content}) when is_binary(content) and content != "", do: content
  defp message_text(_msg), do: nil

  defp message_reasoning(nil), do: nil

  defp message_reasoning(%{reasoning_content: reasoning})
       when is_binary(reasoning) and reasoning != "",
       do: reasoning

  defp message_reasoning(_msg), do: nil

  defp tool_calls(nil), do: []
  defp tool_calls(%{tool_calls: calls}) when is_list(calls), do: calls
  defp tool_calls(_msg), do: []

  defp single_tool_args(msg) do
    case tool_calls(msg) do
      [%{"function" => %{"arguments" => args}}] when is_binary(args) -> pretty_json_string(args)
      _ -> nil
    end
  end

  defp pretty_args(%{"function" => %{"arguments" => args}}) when is_binary(args),
    do: pretty_json_string(args)

  defp pretty_args(call), do: inspect(call)

  defp pretty_json_string(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> str
    end
  end

  defp format_json(nil), do: ""

  defp format_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> str
    end
  end

  defp format_metric(_key, nil), do: "—"
  defp format_metric(key, value) when key in [:latency_ms, :ttfb_ms], do: "#{value}ms"

  defp format_metric(:estimated_cost_usd, %Decimal{} = value),
    do: "$#{Decimal.round(value, 5) |> Decimal.to_string(:normal)}"

  defp format_metric(_key, value), do: to_string(value)

  defp delta_color(:better), do: "text-success"
  defp delta_color(:worse), do: "text-error"
  defp delta_color(_direction), do: "text-base-content/40"

  defp delta_chip(%{direction: :unknown}), do: "—"
  defp delta_chip(%{direction: :even}), do: "±0%"

  defp delta_chip(%{delta_pct: pct}) when is_float(pct) do
    sign = if pct > 0, do: "+", else: ""
    "#{sign}#{pct}%"
  end

  defp delta_chip(_delta), do: "—"

  defp diff_stats_caption(%{granularity: granularity, stats: %{ins: ins, del: del}}) do
    unit = if granularity == :word, do: "words", else: "lines"
    "+#{ins} / −#{del} #{unit}"
  end

  defp blocker_message(:truncated),
    do:
      "The stored request was truncated when it was logged — replaying it would send a different prompt than the original."

  defp blocker_message(:invalid_request_body),
    do: "The stored request body couldn't be decoded."

  defp blocker_message(:missing_messages),
    do: "The stored request has no messages to replay."

  defp blocker_message(other), do: "Replay unavailable: #{inspect(other)}"

  defp replay_error_message(:provider_key_not_found), do: "That provider key no longer exists."
  defp replay_error_message(:invalid_model), do: "Pick or type a model id first."
  defp replay_error_message(:no_routing_configured), do: "No routing step could be built."

  defp replay_error_message(:log_not_persisted),
    do: "The replay ran but its log couldn't be saved."

  defp replay_error_message(reason)
       when reason in [:truncated, :invalid_request_body, :missing_messages],
       do: blocker_message(reason)

  defp replay_error_message(other), do: "Replay failed: #{inspect(other)}"
end
