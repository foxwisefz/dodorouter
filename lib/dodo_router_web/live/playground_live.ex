defmodule DodoRouterWeb.PlaygroundLive do
  @moduledoc """
  A thread you can point at any configured provider key × model, turn by
  turn — switch the model mid-conversation, attach images, and read back
  what each answer cost and how long it took. Every turn is a real dispatch
  through the proxy and lands as a playground request log.
  """
  use DodoRouterWeb, :live_view

  alias DodoRouter.Models
  alias DodoRouter.Playground
  alias DodoRouter.Routers
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouterWeb.ProviderComponents

  @max_images 4
  # Anthropic caps a single image at 5 MB after decoding; the base64 data
  # URL is a third larger again. Bigger uploads are refused here rather
  # than a provider error minutes of typing later.
  @max_image_bytes 5_000_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    routers = Routers.list_routers(user)
    targets = Playground.list_targets(user)

    socket =
      socket
      |> assign(:page_title, "Playground")
      |> assign(:routers, routers)
      |> assign(:router, List.first(routers))
      |> assign(:targets, targets)
      |> assign(:target_form, to_form(default_target(targets), as: :target))
      |> assign(:facts, nil)
      |> assign(:composer_form, to_form(%{"text" => ""}, as: :composer))
      |> assign(:system_prompt, "")
      |> assign(:show_system?, false)
      |> assign(:history, [])
      |> assign(:turn_count, 0)
      |> assign(:sending?, false)
      |> assign(:in_flight, nil)
      |> assign(:totals, empty_totals())
      |> stream(:turns, [])
      |> allow_upload(:images,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: @max_images,
        max_file_size: @max_image_bytes
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    router =
      case params["router_id"] do
        nil -> socket.assigns.router
        id -> Enum.find(socket.assigns.routers, &(&1.id == id)) || socket.assigns.router
      end

    {:noreply, assign(socket, :router, router)}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate_target", %{"target" => params}, socket) do
    # phx-change re-sends the whole form, so a provider-key switch would
    # otherwise carry the previous provider's model along.
    params =
      if params["provider_key_id"] != socket.assigns.target_form[:provider_key_id].value do
        params |> Map.put("model", "") |> Map.put("reasoning_effort", "")
      else
        params
      end

    {:noreply,
     socket
     |> assign(:target_form, to_form(params, as: :target))
     |> assign_facts()}
  end

  def handle_event("select_router", %{"router_id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/playground?router_id=#{id}")}
  end

  def handle_event("validate_composer", %{"composer" => params}, socket) do
    {:noreply, assign(socket, :composer_form, to_form(params, as: :composer))}
  end

  def handle_event("validate_composer", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle_event("toggle_system", _params, socket) do
    {:noreply, assign(socket, :show_system?, not socket.assigns.show_system?)}
  end

  def handle_event("update_system", %{"system" => %{"prompt" => prompt}}, socket) do
    {:noreply, assign(socket, :system_prompt, prompt)}
  end

  def handle_event("send", params, socket) do
    text = params |> get_in(["composer", "text"]) |> to_string() |> String.trim()
    images = consume_images(socket)

    cond do
      socket.assigns.sending? ->
        {:noreply, socket}

      is_nil(socket.assigns.router) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Create a router first — playground turns are logged under one."
         )}

      text == "" and images == [] ->
        {:noreply, socket}

      true ->
        user_turn = %{
          id: next_turn_id(),
          role: :user,
          text: text,
          images: images,
          sent_to: current_target_label(socket)
        }

        {:noreply,
         socket
         |> assign(:composer_form, to_form(%{"text" => ""}, as: :composer))
         |> append_turn(user_turn)
         |> dispatch_turn()}
    end
  end

  # Re-ask the last question on whatever model is selected now — the
  # two-click loop that makes "does the cheaper model handle this?" a
  # comparison rather than a retype.
  def handle_event("ask_again", _params, socket) do
    case Enum.reverse(socket.assigns.history) do
      [%{role: :assistant, status: status} = last | _rest]
      when status in [:done, :error] and not socket.assigns.sending? ->
        {:noreply,
         socket
         |> assign(:history, List.delete_at(socket.assigns.history, -1))
         |> stream_delete(:turns, last)
         |> dispatch_turn()}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_thread", _params, socket) do
    if socket.assigns.sending? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:history, [])
       |> assign(:turn_count, 0)
       |> assign(:totals, empty_totals())
       |> stream(:turns, [], reset: true)}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_turn(socket) do
    %{current_user: user, router: router, history: history, target_form: form} = socket.assigns
    model = String.trim(form[:model].value || "")

    target = %{
      provider_key_id: form[:provider_key_id].value,
      model: model,
      reasoning_effort: form[:reasoning_effort].value
    }

    request =
      Playground.build_request(history, model, system_prompt: socket.assigns.system_prompt)

    turn_id = next_turn_id()

    placeholder = %{
      id: turn_id,
      role: :assistant,
      status: :streaming,
      text: "",
      reasoning: "",
      model: model,
      provider: target_provider(socket, target.provider_key_id),
      key_label: current_target_label(socket)
    }

    lv = self()

    on_delta = fn delta -> send(lv, {:playground_delta, turn_id, delta}) end

    socket
    |> assign(:sending?, true)
    |> assign(:in_flight, turn_id)
    |> append_turn(placeholder)
    |> start_async(:send_turn, fn ->
      Playground.send_turn(user, router, target, request, on_delta: on_delta)
    end)
  end

  @impl true
  def handle_info({:playground_delta, turn_id, delta}, socket) do
    if socket.assigns.in_flight == turn_id do
      {:noreply,
       update_turn(socket, turn_id, fn turn ->
         %{
           turn
           | text: turn.text <> delta.content,
             reasoning: turn.reasoning <> delta.reasoning
         }
       end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:send_turn, {:ok, {:ok, reply}}, socket) do
    turn_id = socket.assigns.in_flight

    socket =
      socket
      |> update_turn(turn_id, fn turn ->
        Map.merge(turn, %{
          status: :done,
          text: reply.text,
          reasoning: reply.reasoning,
          tool_calls: reply.tool_calls,
          model: reply.model,
          finish_reason: reply.finish_reason,
          log_id: reply.log && reply.log.id,
          latency_ms: reply.latency_ms,
          ttfb_ms: reply.ttfb_ms,
          prompt_tokens: reply.prompt_tokens,
          completion_tokens: reply.completion_tokens,
          cache_read_tokens: reply.cache_read_tokens,
          cost_usd: reply.cost_usd,
          list_cost_usd: reply.list_cost_usd
        })
      end)
      |> update(:totals, &add_totals(&1, reply))
      |> finish_sending()

    {:noreply, socket}
  end

  def handle_async(:send_turn, {:ok, {:error, failure}}, socket) do
    socket =
      socket
      |> update_turn(socket.assigns.in_flight, fn turn ->
        Map.merge(turn, %{
          status: :error,
          error: failure.message,
          log_id: failure[:log] && failure.log.id,
          latency_ms: failure[:latency_ms]
        })
      end)
      |> finish_sending()

    {:noreply, socket}
  end

  def handle_async(:send_turn, {:exit, reason}, socket) do
    socket =
      socket
      |> update_turn(socket.assigns.in_flight, fn turn ->
        Map.merge(turn, %{status: :error, error: "The turn crashed: #{inspect(reason)}"})
      end)
      |> finish_sending()

    {:noreply, socket}
  end

  defp finish_sending(socket) do
    socket |> assign(:sending?, false) |> assign(:in_flight, nil)
  end

  # ---------------------------------------------------------------------------
  # Thread state — the history is the source of truth the request is built
  # from; the stream is its rendering, updated one turn at a time so a
  # streaming delta never re-sends the images of every earlier turn.
  # ---------------------------------------------------------------------------

  defp append_turn(socket, turn) do
    socket
    |> update(:history, &(&1 ++ [turn]))
    |> update(:turn_count, &(&1 + 1))
    |> stream_insert(:turns, turn)
  end

  defp update_turn(socket, turn_id, fun) do
    case Enum.find(socket.assigns.history, &(&1.id == turn_id)) do
      nil ->
        socket

      turn ->
        updated = fun.(turn)

        socket
        |> update(:history, fn history ->
          Enum.map(history, &if(&1.id == turn_id, do: updated, else: &1))
        end)
        |> stream_insert(:turns, updated)
    end
  end

  defp next_turn_id, do: "turn-#{System.unique_integer([:positive, :monotonic])}"

  defp consume_images(socket) do
    consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
      data = File.read!(path)

      {:ok,
       %{
         data_url: "data:#{entry.client_type};base64,#{Base.encode64(data)}",
         name: entry.client_name,
         bytes: byte_size(data)
       }}
    end)
  end

  defp empty_totals, do: %{turns: 0, cost_usd: Decimal.new(0), tokens: 0, latency_ms: 0}

  defp add_totals(totals, reply) do
    %{
      turns: totals.turns + 1,
      cost_usd: Decimal.add(totals.cost_usd, reply.cost_usd || Decimal.new(0)),
      tokens: totals.tokens + (reply.prompt_tokens || 0) + (reply.completion_tokens || 0),
      latency_ms: totals.latency_ms + (reply.latency_ms || 0)
    }
  end

  # ---------------------------------------------------------------------------
  # Target helpers
  # ---------------------------------------------------------------------------

  defp default_target(targets) do
    %{"provider_key_id" => default_key_id(targets), "model" => "", "reasoning_effort" => ""}
  end

  defp default_key_id([%{provider_key: key} | _rest]), do: key.id
  defp default_key_id([]), do: nil

  defp assign_facts(socket) do
    form = socket.assigns.target_form
    model = String.trim(form[:model].value || "")

    facts =
      case selected_target(socket.assigns.targets, form[:provider_key_id].value) do
        %{provider_key: key} when model != "" -> Playground.model_facts(key, model)
        _none -> nil
      end

    assign(socket, :facts, facts)
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

  defp target_provider(socket, provider_key_id) do
    case selected_target(socket.assigns.targets, provider_key_id) do
      nil -> nil
      target -> target.provider
    end
  end

  defp current_target_label(socket) do
    form = socket.assigns.target_form

    case selected_target(socket.assigns.targets, form[:provider_key_id].value) do
      nil -> nil
      target -> ProviderComponents.provider_key_option_label(target.provider_key)
    end
  end

  defp target_options(targets) do
    Enum.map(targets, fn target ->
      {ProviderComponents.provider_key_option_label(target.provider_key), target.provider_key.id}
    end)
  end

  defp model_option_label(%{display_name: name, input_price: nil}), do: name

  defp model_option_label(%{display_name: name, input_price: input, output_price: output}) do
    if Decimal.eq?(input, 0) and not is_nil(output) and Decimal.eq?(output, 0),
      do: "#{name} — included in plan",
      else: "#{name} — $#{input}/$#{output} per Mtok"
  end

  defp effort_options(targets, provider_key_id, model) do
    known =
      case selected_target(targets, provider_key_id) do
        %{provider: provider} when is_binary(model) and model != "" ->
          Models.reasoning_efforts_for(provider, model)

        _target ->
          []
      end

    efforts = if known == [], do: RoutingStep.reasoning_efforts(), else: known
    [{"Model default", ""} | Enum.map(efforts, &{&1, &1})]
  end

  defp last_turn_answered?(history) do
    match?(
      [%{role: :assistant, status: status} | _] when status in [:done, :error],
      Enum.reverse(history)
    )
  end

  defp format_tokens(nil), do: "–"
  defp format_tokens(n) when is_integer(n), do: format_compact(n)

  defp context_label(nil), do: nil
  defp context_label(tokens) when is_integer(tokens), do: "#{format_compact(tokens)} ctx"

  defp price_label(%{input_price_per_million: nil}), do: nil

  defp price_label(%{input_price_per_million: input, output_price_per_million: output}) do
    if Decimal.eq?(input, 0) and (is_nil(output) or Decimal.eq?(output, 0)),
      do: "included in plan",
      else: "$#{plain(input)} in / $#{plain(output)} out per Mtok"
  end

  defp plain(nil), do: "?"
  defp plain(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp upload_error_text(:too_large), do: "over 5 MB"
  defp upload_error_text(:too_many_files), do: "at most #{@max_images} images"
  defp upload_error_text(:not_accepted), do: "not an image"
  defp upload_error_text(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl">
        <div class="flex flex-wrap items-end justify-between gap-3 mb-5">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Playground</h1>
            <p class="text-sm text-base-content/60 mt-1">
              Talk to any key × model, switch models mid-thread, attach images. Every turn goes through the proxy and is logged.
            </p>
          </div>
          <form
            :if={length(@routers) > 1}
            id="playground-router-form"
            phx-change="select_router"
            class="flex items-center gap-2"
          >
            <label for="playground-router" class="text-xs font-medium text-base-content/50">
              Log under
            </label>
            <select id="playground-router" name="router_id" class="select select-sm">
              {Phoenix.HTML.Form.options_for_select(
                Enum.map(@routers, &{&1.name, &1.id}),
                @router && @router.id
              )}
            </select>
          </form>
        </div>

        <div
          :if={@routers == []}
          id="playground-no-router"
          class="rounded-2xl border border-dashed border-base-300 p-8 text-center"
        >
          <.icon name="hero-adjustments-horizontal" class="size-8 text-base-content/30 mx-auto mb-3" />
          <p class="font-medium">Create a router first</p>
          <p class="text-sm text-base-content/60 mt-1 mb-4">
            Playground turns are logged under a router, like the traffic it serves.
          </p>
          <.link navigate={~p"/routers/new"} class="btn btn-primary btn-sm">New router</.link>
        </div>

        <div
          :if={@routers != [] and @targets == []}
          id="playground-no-keys"
          class="rounded-2xl border border-dashed border-base-300 p-8 text-center"
        >
          <.icon name="hero-key" class="size-8 text-base-content/30 mx-auto mb-3" />
          <p class="font-medium">No provider keys yet</p>
          <p class="text-sm text-base-content/60 mt-1 mb-4">
            Add a provider key and every model it can reach shows up here.
          </p>
          <.link navigate={~p"/providers?return_to=/playground"} class="btn btn-primary btn-sm">
            Add a provider key
          </.link>
        </div>

        <div :if={@routers != [] and @targets != []} class="space-y-4">
          <%!-- Target picker --%>
          <section class="rounded-2xl border border-base-300/60 bg-base-100 p-4 shadow-sm">
            <.form
              for={@target_form}
              id="playground-form"
              phx-change="validate_target"
              class="flex flex-col md:flex-row md:items-end gap-3"
            >
              <div class="w-full md:w-72">
                <label class="text-xs font-medium text-base-content/50 block mb-1">
                  Provider key
                </label>
                <select
                  name={@target_form[:provider_key_id].name}
                  id="playground-provider-key"
                  class="select select-sm w-full"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    target_options(@targets),
                    @target_form[:provider_key_id].value
                  )}
                </select>
              </div>

              <div class="w-full md:flex-1">
                <label class="text-xs font-medium text-base-content/50 block mb-1">Model</label>
                <input
                  type="text"
                  name={@target_form[:model].name}
                  id="playground-model"
                  value={@target_form[:model].value}
                  list="playground-model-options"
                  placeholder="Pick a model or type any model id…"
                  autocomplete="off"
                  phx-debounce="300"
                  class="input input-sm w-full"
                />
                <datalist id="playground-model-options">
                  <option
                    :for={
                      model <-
                        selected_target_models(@targets, @target_form[:provider_key_id].value)
                    }
                    value={model.id}
                  >
                    {model_option_label(model)}
                  </option>
                </datalist>
              </div>

              <div class="w-full md:w-40">
                <label class="text-xs font-medium text-base-content/50 block mb-1">Reasoning</label>
                <select
                  name={@target_form[:reasoning_effort].name}
                  id="playground-effort"
                  class="select select-sm w-full"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    effort_options(
                      @targets,
                      @target_form[:provider_key_id].value,
                      @target_form[:model].value
                    ),
                    @target_form[:reasoning_effort].value
                  )}
                </select>
              </div>
            </.form>

            <%!-- What the catalog says this model can do --%>
            <div
              id="playground-facts"
              class="mt-3 flex flex-wrap items-center gap-1.5 text-xs min-h-6"
            >
              <%= cond do %>
                <% String.trim(@target_form[:model].value || "") == "" -> %>
                  <span class="text-base-content/40">
                    Pick a model to see what the catalog says it supports.
                  </span>
                <% is_nil(@facts) -> %>
                  <span class="text-base-content/50">
                    <.icon name="hero-question-mark-circle" class="size-3.5 inline -mt-0.5" />
                    Not in the catalog — send a turn and the provider will tell you.
                  </span>
                <% true -> %>
                  <.capability id="cap-vision" on={@facts.supports_vision} label="Images" />
                  <.capability id="cap-tools" on={@facts.supports_function_calling} label="Tools" />
                  <.capability id="cap-reasoning" on={@facts.supports_reasoning} label="Reasoning" />
                  <.capability
                    id="cap-cache"
                    on={@facts.supports_prompt_caching}
                    label="Prompt cache"
                  />
                  <span
                    :if={context_label(@facts.max_input_tokens)}
                    class="badge badge-ghost badge-sm font-mono"
                  >
                    {context_label(@facts.max_input_tokens)}
                  </span>
                  <span :if={price_label(@facts)} class="text-base-content/50 ml-1">
                    {price_label(@facts)}
                  </span>
              <% end %>
            </div>

            <%!-- System prompt --%>
            <div class="mt-3 border-t border-base-300/50 pt-3">
              <button
                type="button"
                id="playground-toggle-system"
                phx-click="toggle_system"
                class="flex items-center gap-1.5 text-xs font-medium text-base-content/60 hover:text-base-content transition-colors"
              >
                <.icon
                  name="hero-chevron-right-micro"
                  class={"size-3.5 transition-transform #{if @show_system?, do: "rotate-90"}"}
                /> System prompt
                <span :if={String.trim(@system_prompt) != ""} class="badge badge-accent badge-xs">
                  set
                </span>
              </button>
              <form
                :if={@show_system?}
                id="playground-system-form"
                phx-change="update_system"
                class="mt-2"
              >
                <textarea
                  id="playground-system"
                  name="system[prompt]"
                  rows="3"
                  phx-debounce="300"
                  placeholder="Optional. Sent as the system message on every turn."
                  class="textarea textarea-sm w-full font-mono text-xs"
                >{@system_prompt}</textarea>
              </form>
            </div>
          </section>

          <%!-- Thread --%>
          <section class="rounded-2xl border border-base-300/60 bg-base-100 shadow-sm">
            <div class="flex items-center justify-between px-4 py-2.5 border-b border-base-300/50">
              <div id="playground-totals" class="flex items-center gap-3 text-xs text-base-content/60">
                <span :if={@turn_count == 0}>New thread</span>
                <span :if={@turn_count > 0 and @totals.turns == 0}>No answer yet</span>
                <span :if={@totals.turns > 0}>
                  {pluralize(@totals.turns, "answer")}
                </span>
                <span :if={@totals.turns > 0} class="font-mono">
                  {format_usd(@totals.cost_usd)}
                </span>
                <span :if={@totals.turns > 0} class="font-mono">
                  {format_tokens(@totals.tokens)} tok
                </span>
                <span :if={@totals.turns > 0} class="font-mono">
                  {format_ms(@totals.latency_ms / @totals.turns)} avg
                </span>
              </div>
              <div class="flex items-center gap-1">
                <button
                  :if={last_turn_answered?(@history)}
                  type="button"
                  id="playground-ask-again"
                  phx-click="ask_again"
                  disabled={@sending?}
                  title="Send the last question again to the model selected above"
                  class="btn btn-ghost btn-xs gap-1"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" /> Ask again
                </button>
                <button
                  :if={@turn_count > 0}
                  type="button"
                  id="playground-clear"
                  phx-click="clear_thread"
                  disabled={@sending?}
                  class="btn btn-ghost btn-xs gap-1"
                >
                  <.icon name="hero-trash" class="size-3.5" /> Clear
                </button>
              </div>
            </div>

            <div class="p-4">
              <div
                :if={@turn_count == 0}
                id="playground-empty-state"
                class="py-10 text-center text-sm text-base-content/50"
              >
                <.icon name="hero-chat-bubble-left-right" class="size-8 mx-auto mb-3 opacity-40" />
                Pick a model, say something, and watch what comes back — then switch models and ask again.
              </div>

              <div id="playground-thread" phx-update="stream" class="space-y-4">
                <div :for={{dom_id, turn} <- @streams.turns} id={dom_id}>
                  <.turn turn={turn} />
                </div>
              </div>
            </div>

            <%!-- Composer --%>
            <div class="border-t border-base-300/50 p-3">
              <.form
                for={@composer_form}
                id="playground-composer"
                phx-change="validate_composer"
                phx-submit="send"
                class="space-y-2"
              >
                <div
                  :if={@uploads.images.entries != []}
                  id="playground-pending-images"
                  class="flex flex-wrap gap-2"
                >
                  <div :for={entry <- @uploads.images.entries} class="relative group">
                    <.live_img_preview
                      entry={entry}
                      class="h-16 w-16 rounded-lg object-cover border border-base-300"
                    />
                    <button
                      type="button"
                      phx-click="cancel_upload"
                      phx-value-ref={entry.ref}
                      aria-label="Remove image"
                      class="absolute -top-1.5 -right-1.5 rounded-full bg-base-100 border border-base-300 p-0.5 shadow-sm opacity-0 group-hover:opacity-100 transition-opacity"
                    >
                      <.icon name="hero-x-mark-micro" class="size-3" />
                    </button>
                    <p
                      :for={err <- upload_errors(@uploads.images, entry)}
                      class="text-[10px] text-error mt-0.5"
                    >
                      {upload_error_text(err)}
                    </p>
                  </div>
                </div>

                <p
                  :if={@uploads.images.entries != [] and Playground.rejects_images?(@facts)}
                  id="playground-vision-warning"
                  class="flex items-center gap-1.5 text-xs text-warning"
                >
                  <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
                  The catalog says {@facts.display_name} does not take images. Sending anyway shows you what the provider does with them.
                </p>
                <p :for={err <- upload_errors(@uploads.images)} class="text-xs text-error">
                  {upload_error_text(err)}
                </p>

                <div class="flex items-end gap-2">
                  <label
                    for={@uploads.images.ref}
                    title="Attach up to 4 images"
                    class="btn btn-ghost btn-sm btn-square shrink-0"
                  >
                    <.icon name="hero-photo" class="size-5" />
                    <.live_file_input upload={@uploads.images} class="hidden" />
                  </label>
                  <textarea
                    id="playground-input"
                    name={@composer_form[:text].name}
                    rows="2"
                    placeholder="Ask something…"
                    class="textarea textarea-sm flex-1 resize-y"
                    disabled={@sending?}
                  >{@composer_form[:text].value}</textarea>
                  <button
                    type="submit"
                    id="playground-send"
                    disabled={@sending?}
                    class="btn btn-primary btn-sm gap-1.5 shrink-0"
                  >
                    <%= if @sending? do %>
                      <span class="loading loading-spinner loading-xs"></span> Sending
                    <% else %>
                      <.icon name="hero-paper-airplane" class="size-4" /> Send
                    <% end %>
                  </button>
                </div>
              </.form>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true

  defp capability(assigns) do
    ~H"""
    <span
      id={@id}
      data-on={to_string(@on)}
      class={[
        "badge badge-sm gap-1",
        @on && "badge-success badge-outline",
        !@on && "badge-ghost text-base-content/40 line-through"
      ]}
    >
      <.icon name={if(@on, do: "hero-check-micro", else: "hero-x-mark-micro")} class="size-3" />
      {@label}
    </span>
    """
  end

  attr :turn, :map, required: true

  defp turn(%{turn: %{role: :user}} = assigns) do
    ~H"""
    <div class="flex justify-end" data-role="user">
      <div class="playground-turn playground-turn-user max-w-[85%] rounded-2xl rounded-br-md bg-accent/10 px-4 py-2.5">
        <div :if={@turn.images != []} class="flex flex-wrap gap-2 mb-2">
          <img
            :for={image <- @turn.images}
            src={image.data_url}
            alt={image.name}
            title={image.name}
            class="h-32 max-w-56 rounded-lg object-cover border border-base-300/60"
          />
        </div>
        <p :if={@turn.text != ""} class="text-sm whitespace-pre-wrap break-words">{@turn.text}</p>
      </div>
    </div>
    """
  end

  defp turn(%{turn: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="flex justify-start" data-role="assistant" data-status={@turn.status}>
      <div class={[
        "playground-turn playground-turn-assistant max-w-[85%] rounded-2xl rounded-bl-md border px-4 py-2.5",
        @turn.status == :error && "playground-turn-error border-error/40 bg-error/5",
        @turn.status != :error && "border-base-300/60 bg-base-200/40"
      ]}>
        <div class="flex items-center gap-2 mb-1.5 text-xs">
          <.provider_logo slug={@turn.provider || "unknown"} class="w-3.5 h-3.5" />
          <span class="font-semibold font-mono">{@turn.model}</span>
          <span :if={@turn.status == :streaming} class="flex items-center gap-1 text-base-content/50">
            <span class="loading loading-dots loading-xs"></span>
          </span>
        </div>

        <details :if={@turn.reasoning != ""} class="mb-2 group">
          <summary class="cursor-pointer text-xs text-base-content/50 hover:text-base-content select-none">
            Reasoning
            <span class="font-mono">({format_compact(String.length(@turn.reasoning))} chars)</span>
          </summary>
          <p class="mt-1 text-xs text-base-content/60 whitespace-pre-wrap break-words border-l-2 border-base-300 pl-2">
            {@turn.reasoning}
          </p>
        </details>

        <p :if={@turn.status == :error} class="text-sm text-error">{@turn.error}</p>
        <p
          :if={@turn.status != :error and @turn.text != ""}
          class="text-sm whitespace-pre-wrap break-words"
        >
          {@turn.text}
        </p>
        <p
          :if={@turn.status == :done and @turn.text == "" and (@turn[:tool_calls] || []) != []}
          class="text-sm text-base-content/60 italic"
        >
          The model answered with {pluralize(length(@turn.tool_calls), "tool call")} instead of text.
        </p>
        <p
          :if={@turn.status == :done and @turn.text == "" and (@turn[:tool_calls] || []) == []}
          class="text-sm text-base-content/40 italic"
        >
          Empty answer.
        </p>

        <div
          :if={@turn.status in [:done, :error]}
          class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/50 font-mono"
        >
          <span :if={@turn[:latency_ms]} title="Total latency">
            {format_ms(@turn.latency_ms)}
          </span>
          <span :if={@turn[:ttfb_ms]} title="Time to first byte">
            ttfb {format_ms(@turn.ttfb_ms)}
          </span>
          <span :if={@turn[:prompt_tokens]} title="Prompt → completion tokens">
            {format_tokens(@turn.prompt_tokens)} → {format_tokens(@turn[:completion_tokens])} tok
          </span>
          <span
            :if={@turn[:cache_read_tokens] && @turn.cache_read_tokens > 0}
            title="Read from prompt cache"
          >
            {format_tokens(@turn.cache_read_tokens)} cached
          </span>
          <span :if={@turn[:cost_usd]} title="Estimated cost at this key's pricing">
            {format_usd(@turn.cost_usd)}
          </span>
          <.link
            :if={@turn[:log_id]}
            navigate={~p"/logs/#{@turn.log_id}"}
            class="playground-log-link text-accent hover:underline"
          >
            View log
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
