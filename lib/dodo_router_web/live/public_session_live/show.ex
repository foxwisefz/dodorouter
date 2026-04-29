defmodule DodoRouterWeb.PublicSessionLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.SessionTree

  import DodoRouterWeb.PromptComponents

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    case Logs.list_public_logs_for_session(session_id) do
      [] ->
        {:ok,
         socket
         |> put_flash(:error, "No published prompts in this session.")
         |> redirect(to: ~p"/")}

      logs ->
        tree = SessionTree.build(logs)
        first_log = List.first(logs)
        owner_username = first_log.router && first_log.router.user && first_log.router.user.username

        {:ok,
         socket
         |> assign(:page_title, "Session #{String.slice(session_id, 0, 8)}")
         |> assign(:session_id, session_id)
         |> assign(:tree, tree)
         |> assign(:logs, logs)
         |> assign(:owner_username, owner_username)
         |> assign(:selected_log_id, nil)
         |> assign(:selected_messages, [])}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_id = params["log"]

    selected_messages =
      if selected_id do
        SessionTree.find_branch(socket.assigns.tree, selected_id) || []
      else
        []
      end

    {:noreply,
     socket
     |> assign(:selected_log_id, selected_id)
     |> assign(:selected_messages, selected_messages)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto py-8 px-4">
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Session tree</h1>
        <p class="text-sm text-base-content/60 mt-1">
          {length(@logs)} published prompts share a conversation prefix. Click a leaf to view that branch.
          <%= if @owner_username do %>
            <span>by</span>
            <.link navigate={~p"/u/#{@owner_username}"} class="text-primary hover:underline">
              @{@owner_username}
            </.link>
          <% end %>
        </p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-12 gap-6">
        <div class="lg:col-span-5 bg-base-100 rounded-lg border border-base-300/40 p-4 overflow-x-auto">
          <.session_tree tree={@tree} selected_log_id={@selected_log_id} />
        </div>

        <div class="lg:col-span-7">
          <%= if @selected_log_id do %>
            <.conversation
              messages={@selected_messages}
              response={nil}
              editable={false}
            />
            <div class="mt-4 text-xs">
              <.link
                navigate={~p"/p/#{find_log_slug(@logs, @selected_log_id)}"}
                class="text-primary hover:underline"
              >
                Open this branch on its own page →
              </.link>
            </div>
          <% else %>
            <div class="text-center py-16 text-base-content/40 text-sm">
              Select a leaf in the tree to inspect that conversation branch.
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp find_log_slug(logs, log_id) do
    Enum.find_value(logs, fn log ->
      if log.id == log_id, do: log.public_slug
    end)
  end
end
