defmodule DodoRouterWeb.PublicLogLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Forks

  import DodoRouterWeb.PromptComponents

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Logs.get_public_log_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That prompt does not exist or has been unpublished.")
         |> redirect(to: ~p"/")}

      log ->
        {messages, params} = MessageNormalizer.parse_request_body(log.public_request_body)
        response = MessageNormalizer.parse_response_body(log.public_response_body)

        owner_username = log.router && log.router.user && log.router.user.username

        socket =
          socket
          |> assign(:page_title, log.public_title || "Shared prompt")
          |> assign(:log, log)
          |> assign(:messages, messages)
          |> assign(:edited_messages, messages)
          |> assign(:original_messages, messages)
          |> assign(:response, response)
          |> assign(:model, params["model"])
          |> assign(:provider, log.final_provider)
          |> assign(:owner_username, owner_username)
          |> assign(:runnable_routers, runnable_routers(socket))
          |> assign(:selected_router_id, default_router_id(socket))

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("edit_message", %{"index" => idx, "value" => value}, socket) do
    idx = String.to_integer(idx)
    edited = List.update_at(socket.assigns.edited_messages, idx, &Map.put(&1, :content, value))
    {:noreply, assign(socket, :edited_messages, edited)}
  end

  def handle_event("add_turn", %{"role" => role}, socket) do
    blank = %{role: role, content: "", tool_calls: nil, tool_call_id: nil, name: nil}
    {:noreply, assign(socket, :edited_messages, socket.assigns.edited_messages ++ [blank])}
  end

  def handle_event("remove_turn", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, assign(socket, :edited_messages, List.delete_at(socket.assigns.edited_messages, idx))}
  end

  def handle_event("reset_messages", _params, socket) do
    {:noreply, assign(socket, :edited_messages, socket.assigns.original_messages)}
  end

  def handle_event("select_router", %{"router_id" => router_id}, socket) do
    {:noreply, assign(socket, :selected_router_id, router_id)}
  end

  def handle_event("run_fork", _params, socket) do
    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:noreply,
         socket
         |> put_flash(:info, "Log in to run this prompt with your own keys.")
         |> redirect(to: ~p"/users/log-in")}

      socket.assigns.runnable_routers == [] ->
        {:noreply,
         socket
         |> put_flash(:error, "Create a router first to run forked prompts.")
         |> push_navigate(to: ~p"/routers/new")}

      is_nil(socket.assigns.selected_router_id) ->
        {:noreply, put_flash(socket, :error, "Select a router to run with.")}

      true ->
        case Forks.run_fork(
               socket.assigns.current_user,
               socket.assigns.log,
               socket.assigns.edited_messages,
               %{router_id: socket.assigns.selected_router_id}
             ) do
          {:ok, new_log} ->
            {:noreply,
             socket
             |> put_flash(:info, "Forked! Your run is logged below.")
             |> push_navigate(to: ~p"/logs/#{new_log.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not run fork: #{inspect(reason)}")}
        end
    end
  end

  defp runnable_routers(socket) do
    case socket.assigns[:current_user] do
      nil -> []
      user -> Forks.runnable_routers(user)
    end
  end

  defp default_router_id(socket) do
    case runnable_routers(socket) do
      [first | _] -> first.id
      [] -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto py-8 px-4">
      <div class="mb-6 flex items-baseline gap-3">
        <h1 class="text-2xl font-bold">{@log.public_title || "Shared prompt"}</h1>
        <%= if @owner_username do %>
          <.link navigate={~p"/u/#{@owner_username}"} class="text-sm text-base-content/50 hover:text-primary">
            @{@owner_username}
          </.link>
        <% end %>
      </div>

      <.conversation
        messages={@edited_messages}
        response={@response}
        model={@model}
        provider={@provider}
        editable={true}
        edited_messages={@edited_messages}
        run_disabled={@runnable_routers == []}
        run_label={run_label(@current_user, @runnable_routers)}
      >
        <:run_controls>
          <%= if @current_user && @runnable_routers != [] do %>
            <div class="flex items-center gap-2 text-xs">
              <label class="text-base-content/60" for="router-select">Run via router:</label>
              <select
                id="router-select"
                class="select select-bordered select-xs"
                phx-change="select_router"
                name="router_id"
              >
                <%= for router <- @runnable_routers do %>
                  <option value={router.id} selected={router.id == @selected_router_id}>
                    {router.name}
                  </option>
                <% end %>
              </select>
            </div>
          <% end %>
        </:run_controls>
      </.conversation>

      <p class="mt-8 pt-4 border-t border-base-300/40 text-xs text-base-content/40 text-center">
        Powered by <.link navigate={~p"/"} class="hover:text-primary">DodoRouter</.link>.
        Open prompts, like open source.
      </p>
    </div>
    """
  end

  defp run_label(nil, _), do: "Log in to run with your keys"
  defp run_label(_user, []), do: "Create a router to run"
  defp run_label(_user, _routers), do: "Run with my keys"
end
