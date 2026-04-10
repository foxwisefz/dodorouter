defmodule DodoRouter.Projects do
  @moduledoc """
  The Projects context - API keys, routing configuration.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Projects.{Project, RoutingStep}
  alias DodoRouter.Accounts.User

  # Project CRUD

  def list_projects(%User{} = user) do
    Repo.all(from p in Project, where: p.user_id == ^user.id, order_by: [desc: p.inserted_at])
  end

  def get_project!(%User{} = user, id) do
    Repo.get_by!(Project, id: id, user_id: user.id)
  end

  def get_project(%User{} = user, id) do
    Repo.get_by(Project, id: id, user_id: user.id)
  end

  def get_project_by_slug(%User{} = user, slug) do
    Repo.get_by(Project, slug: slug, user_id: user.id)
  end

  def get_project_by_api_key(api_key) do
    hash = Project.hash_api_key(api_key)
    Repo.get_by(Project, api_key_hash: hash)
  end

  def create_project(%User{} = user, attrs) do
    {api_key, hash, prefix} = generate_api_key()

    result =
      %Project{}
      |> Project.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user.id)
      |> Ecto.Changeset.put_change(:api_key_hash, hash)
      |> Ecto.Changeset.put_change(:api_key_prefix, prefix)
      |> Repo.insert()

    case result do
      {:ok, project} -> {:ok, project, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end

  def regenerate_api_key(%Project{} = project) do
    {api_key, hash, prefix} = generate_api_key()

    result =
      project
      |> Ecto.Changeset.change(%{api_key_hash: hash, api_key_prefix: prefix})
      |> Repo.update()

    case result do
      {:ok, project} -> {:ok, project, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp generate_api_key do
    prefix = "sk-dodo-"

    random_part =
      :crypto.strong_rand_bytes(24)
      |> Base.url_encode64(padding: false)

    full_key = prefix <> random_part
    hash = Project.hash_api_key(full_key)
    display_prefix = String.slice(full_key, 0, 12)

    {full_key, hash, display_prefix}
  end

  # Routing Steps

  def list_routing_steps(%Project{} = project) do
    Repo.all(
      from s in RoutingStep,
        where: s.project_id == ^project.id,
        order_by: [asc: s.position]
    )
  end

  def get_routing_step!(id), do: Repo.get!(RoutingStep, id)

  def create_routing_step(%Project{} = project, attrs) do
    next_position = get_next_position(project)

    %RoutingStep{}
    |> RoutingStep.create_changeset(attrs, project.id, next_position)
    |> Repo.insert()
  end

  def update_routing_step(%RoutingStep{} = step, attrs) do
    step
    |> RoutingStep.changeset(attrs)
    |> Repo.update()
  end

  def delete_routing_step(%RoutingStep{} = step) do
    Repo.delete(step)
  end

  def reorder_routing_steps(%Project{} = project, step_ids) when is_list(step_ids) do
    Repo.transaction(fn ->
      step_ids
      |> Enum.with_index()
      |> Enum.each(fn {step_id, position} ->
        from(s in RoutingStep, where: s.id == ^step_id and s.project_id == ^project.id)
        |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  def change_routing_step(%RoutingStep{} = step, attrs \\ %{}) do
    RoutingStep.changeset(step, attrs)
  end

  defp get_next_position(%Project{} = project) do
    query =
      from s in RoutingStep,
        where: s.project_id == ^project.id,
        select: max(s.position)

    case Repo.one(query) do
      nil -> 0
      max -> max + 1
    end
  end

  # Preloading

  def with_routing_steps(%Project{} = project) do
    Repo.preload(project, routing_steps: from(s in RoutingStep, order_by: [asc: s.position]))
  end
end
