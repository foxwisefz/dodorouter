defmodule DodoRouterWeb.PreferencesController do
  use DodoRouterWeb, :controller

  alias DodoRouter.Accounts

  plug :require_authenticated_user

  def update(conn, %{"sidebar_collapsed" => collapsed}) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_preferences(user, %{"sidebar_collapsed" => collapsed}) do
      {:ok, _user} ->
        json(conn, %{ok: true})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, %{"theme" => theme}) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_preferences(user, %{"theme" => theme}) do
      {:ok, _user} ->
        json(conn, %{ok: true})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid params"})
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "unauthenticated"})
      |> halt()
    end
  end
end
