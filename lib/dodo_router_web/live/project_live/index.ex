defmodule DodoRouterWeb.ProjectLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Projects
  alias DodoRouter.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :projects, Projects.list_projects())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Project")
    |> assign(:project, %Project{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Projects")
    |> assign(:project, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(id)
    {:ok, _} = Projects.delete_project(project)

    {:noreply, stream_delete(socket, :projects, project)}
  end

  @impl true
  def handle_info({DodoRouterWeb.ProjectLive.FormComponent, {:saved, project, api_key}}, socket) do
    socket =
      socket
      |> stream_insert(:projects, project, at: 0)
      |> assign(:show_api_key, api_key)

    {:noreply, socket}
  end

  def handle_info({DodoRouterWeb.ProjectLive.FormComponent, {:saved, project}}, socket) do
    {:noreply, stream_insert(socket, :projects, project, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto">
      <.header>
        Projects
        <:actions>
          <.link patch={~p"/projects/new"}>
            <.button>New Project</.button>
          </.link>
        </:actions>
      </.header>

      <.modal :if={@live_action == :new} id="project-modal" show on_cancel={JS.patch(~p"/projects")}>
        <.live_component
          module={DodoRouterWeb.ProjectLive.FormComponent}
          id={@project.id || :new}
          title={@page_title}
          action={@live_action}
          project={@project}
          patch={~p"/projects"}
        />
      </.modal>

      <div :if={assigns[:show_api_key]} class="mt-4 p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
        <p class="font-semibold text-yellow-800">Save your API key - it won't be shown again:</p>
        <code class="block mt-2 p-2 bg-yellow-100 rounded font-mono text-sm break-all">
          <%= @show_api_key %>
        </code>
      </div>

      <.table id="projects" rows={@streams.projects} row_click={fn {_id, project} -> JS.navigate(~p"/projects/#{project}") end}>
        <:col :let={{_id, project}} label="Name"><%= project.name %></:col>
        <:col :let={{_id, project}} label="Slug"><%= project.slug %></:col>
        <:col :let={{_id, project}} label="API Key"><code class="text-xs"><%= project.api_key_prefix %>...</code></:col>
        <:col :let={{_id, project}} label="Created"><%= Calendar.strftime(project.inserted_at, "%Y-%m-%d") %></:col>
        <:action :let={{_id, project}}>
          <.link navigate={~p"/projects/#{project}"}>View</.link>
        </:action>
        <:action :let={{id, project}}>
          <.link
            phx-click={JS.push("delete", value: %{id: project.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </div>
    """
  end
end
