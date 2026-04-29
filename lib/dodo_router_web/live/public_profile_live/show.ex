defmodule DodoRouterWeb.PublicProfileLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    logs = Logs.list_public_logs_for_username(username)

    {:ok,
     socket
     |> assign(:page_title, "@#{username}")
     |> assign(:username, username)
     |> assign(:logs, logs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto py-8 px-4">
      <div class="mb-8">
        <h1 class="text-3xl font-bold">@{@username}</h1>
        <p class="text-sm text-base-content/60 mt-1">
          {length(@logs)} published {if length(@logs) == 1, do: "prompt", else: "prompts"}
        </p>
      </div>

      <%= if @logs == [] do %>
        <div class="text-center py-16 text-base-content/40 text-sm">
          Nothing published yet.
        </div>
      <% else %>
        <div class="space-y-3">
          <%= for log <- @logs do %>
            <.link
              navigate={~p"/p/#{log.public_slug}"}
              class="block p-4 rounded-lg border border-base-300/40 hover:border-primary/40 hover:bg-base-200/30 transition"
            >
              <div class="flex items-baseline justify-between gap-3">
                <h3 class="font-semibold truncate">
                  {log.public_title || "Untitled prompt"}
                </h3>
                <span class="text-xs text-base-content/40 font-mono shrink-0">
                  {log.final_model}
                </span>
              </div>
              <p class="text-sm text-base-content/60 mt-1 line-clamp-2">
                {snippet(log)}
              </p>
            </.link>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp snippet(log) do
    {messages, _} = MessageNormalizer.parse_request_body(log.public_request_body)

    case Enum.find(messages, &(&1.role == "user")) do
      nil -> ""
      msg -> msg.content |> to_string() |> String.slice(0, 200)
    end
  end
end
