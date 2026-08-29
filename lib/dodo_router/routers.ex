defmodule DodoRouter.Routers do
  @moduledoc """
  The Routers context - API keys, routing configuration.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Routers.{Router, RoutingStep}
  alias DodoRouter.Accounts.User

  # Router CRUD

  def list_routers(%User{} = user) do
    Repo.all(from r in Router, where: r.user_id == ^user.id, order_by: [desc: r.inserted_at])
  end

  @router_colors ~w(blue purple amber rose emerald sky orange indigo)

  def list_routers_with_step_count(%User{} = user) do
    from(r in Router,
      left_join: s in assoc(r, :routing_steps),
      where: r.user_id == ^user.id,
      group_by: r.id,
      order_by: [desc: r.inserted_at],
      select: %{id: r.id, name: r.name, slug: r.slug, step_count: count(s.id)}
    )
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.map(fn {router, idx} ->
      Map.put(router, :color, Enum.at(@router_colors, rem(idx, length(@router_colors))))
    end)
  end

  def get_router!(%User{} = user, id) do
    Repo.get_by!(Router, id: id, user_id: user.id)
  end

  def get_router(%User{} = user, id) do
    Repo.get_by(Router, id: id, user_id: user.id)
  end

  def get_router_by_slug(%User{} = user, slug) do
    Repo.get_by(Router, slug: slug, user_id: user.id)
  end

  def get_router_by_slug(slug) do
    Repo.get_by(Router, slug: slug)
  end

  def get_router_by_api_key(api_key) do
    hash = Router.hash_api_key(api_key)

    Repo.one(
      from r in Router,
        where: r.api_key_hash == ^hash,
        join: u in assoc(r, :user),
        preload: [user: u]
    )
  end

  def create_router(%User{} = user, attrs) do
    {api_key, hash, prefix} = generate_api_key()

    result =
      %Router{}
      |> Router.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user.id)
      |> Ecto.Changeset.put_change(:api_key_hash, hash)
      |> Ecto.Changeset.put_change(:api_key_prefix, prefix)
      |> Repo.insert()

    case result do
      {:ok, router} ->
        broadcast_router_change(router, :router_created)
        {:ok, router, api_key}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_router(%Router{} = router, attrs) do
    router
    |> Router.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast(:router_updated)
  end

  def delete_router(%Router{} = router) do
    router
    |> Repo.delete()
    |> tap_broadcast(:router_deleted)
  end

  @doc """
  Topic carrying `{:router_created | :router_updated | :router_deleted, router}`
  messages for all routers belonging to a user (used by the sidebar).
  """
  def user_routers_topic(user_id), do: "user:#{user_id}:routers"

  defp tap_broadcast({:ok, router} = result, event) do
    broadcast_router_change(router, event)
    result
  end

  defp tap_broadcast(result, _event), do: result

  defp broadcast_router_change(%Router{} = router, event) do
    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      user_routers_topic(router.user_id),
      {event, router}
    )
  end

  def change_router(%Router{} = router, attrs \\ %{}) do
    Router.changeset(router, attrs)
  end

  def regenerate_api_key(%Router{} = router) do
    {api_key, hash, prefix} = generate_api_key()

    result =
      router
      |> Ecto.Changeset.change(%{api_key_hash: hash, api_key_prefix: prefix})
      |> Repo.update()

    case result do
      {:ok, router} -> {:ok, router, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp generate_api_key do
    prefix = "sk-dodo-"

    random_part =
      :crypto.strong_rand_bytes(24)
      |> Base.url_encode64(padding: false)

    full_key = prefix <> random_part
    hash = Router.hash_api_key(full_key)
    display_prefix = String.slice(full_key, 0, 12)

    {full_key, hash, display_prefix}
  end

  # Routing Steps

  def list_routing_steps(%Router{} = router) do
    Repo.all(
      from s in RoutingStep,
        where: s.router_id == ^router.id,
        order_by: [asc: s.position],
        preload: [:provider_key]
    )
  end

  def get_routing_step!(router, id) do
    Repo.get_by!(RoutingStep, id: id, router_id: router.id)
  end

  def create_routing_step(%Router{} = router, attrs) do
    next_position = get_next_position(router)

    %RoutingStep{}
    |> RoutingStep.create_changeset(attrs, router.id, next_position)
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

  def reorder_routing_steps(%Router{} = router, step_ids) when is_list(step_ids) do
    Repo.transaction(fn ->
      # First, shift all positions to temporary negative values to avoid
      # unique constraint collisions when swapping positions
      step_ids
      |> Enum.with_index()
      |> Enum.each(fn {step_id, idx} ->
        from(s in RoutingStep, where: s.id == ^step_id and s.router_id == ^router.id)
        |> Repo.update_all(set: [position: -(idx + 1)])
      end)

      # Then set the final positions
      step_ids
      |> Enum.with_index()
      |> Enum.each(fn {step_id, idx} ->
        from(s in RoutingStep, where: s.id == ^step_id and s.router_id == ^router.id)
        |> Repo.update_all(set: [position: -(idx + 1)])
      end)

      step_ids
      |> Enum.with_index()
      |> Enum.each(fn {step_id, position} ->
        from(s in RoutingStep, where: s.id == ^step_id and s.router_id == ^router.id)
        |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  def change_routing_step(%RoutingStep{} = step, attrs \\ %{}) do
    RoutingStep.changeset(step, attrs)
  end

  defp get_next_position(%Router{} = router) do
    query =
      from s in RoutingStep,
        where: s.router_id == ^router.id,
        select: max(s.position)

    case Repo.one(query) do
      nil -> 0
      max -> max + 1
    end
  end

  # Preloading

  def with_routing_steps(%Router{} = router) do
    Repo.preload(router,
      routing_steps: from(s in RoutingStep, order_by: [asc: s.position], preload: [:provider_key])
    )
  end
end
