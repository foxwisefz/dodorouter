defmodule DodoRouterWeb.RouterLive.FormComponent do
  use DodoRouterWeb, :live_component

  alias DodoRouter.Routers

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
      </.header>

      <.simple_form
        for={@form}
        id="router-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Router</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{router: router} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Routers.change_router(router))
     end)}
  end

  @impl true
  def handle_event("validate", %{"router" => router_params}, socket) do
    changeset = Routers.change_router(socket.assigns.router, router_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"router" => router_params}, socket) do
    save_router(socket, socket.assigns.action, router_params)
  end

  defp save_router(socket, :edit, router_params) do
    case Routers.update_router(socket.assigns.router, router_params) do
      {:ok, router} ->
        notify_parent({:saved, router})

        {:noreply,
         socket
         |> put_flash(:info, "Router updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_router(socket, :new, router_params) do
    case Routers.create_router(socket.assigns.current_user, router_params) do
      {:ok, router, api_key} ->
        notify_parent({:saved, router, api_key})

        {:noreply,
         socket
         |> put_flash(:info, "Router created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
