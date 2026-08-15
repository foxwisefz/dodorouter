defmodule DodoRouter.Models.CatalogFreshnessTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Models

  # models.dev has no deprecation field: `claude-3-5-sonnet-20240620` is not
  # marked retired, it is simply gone from api.json. "Seen in the most recent
  # sync" is therefore the only signal we can have, and offering a model the
  # catalog stopped listing is how an evaluation spends a run discovering
  # that a provider retired it.
  defp model!(attrs) do
    {:ok, model} =
      Models.upsert_model(
        Map.merge(
          %{
            provider_slug: "test_provider",
            model_id: "m-#{System.unique_integer([:positive])}",
            display_name: "M"
          },
          attrs
        )
      )

    model
  end

  defp seen_at(model, datetime) do
    model
    |> Ecto.Changeset.change(last_seen_at: datetime)
    |> Repo.update!()
  end

  describe "a provider's hardcoded adapter list" do
    test "is a fallback for an empty catalog, never an addendum to a real one" do
      # `claude-3-5-haiku-20241022` was offered by a picker and answered 404.
      # It is in no catalog row at all — it comes from the adapter's own
      # `models:` list, written mid-2025 and never revisited. Appending that
      # list to a synced catalog reintroduces every model it has outlived,
      # and no catalog filtering can see them because they are not rows.
      now = DateTime.utc_now()
      model!(%{model_id: "from-catalog"}) |> seen_at(now)

      assert Models.offerable_model_ids("test_provider", ["hardcoded-old-model"]) ==
               ["from-catalog"]
    end

    test "is used when we have no catalog for that provider" do
      # Providers we cannot sync, and every provider before the first sync.
      assert Models.offerable_model_ids("provider-we-never-synced", ["a", "b"]) == ["a", "b"]
    end
  end

  describe "retired?/2" do
    test "true only when a model we hold was left out of the latest sync" do
      now = DateTime.utc_now()

      model!(%{model_id: "current"}) |> seen_at(now)
      model!(%{model_id: "gone"}) |> seen_at(DateTime.add(now, -40, :day))

      assert Models.retired?("test_provider", "gone")
      refute Models.retired?("test_provider", "current")
    end

    test "a model we never had is unknown, not retired" do
      # A custom or unlisted model id is not evidence of retirement, and
      # warning about one would cry wolf on every hand-typed model.
      model!(%{model_id: "current"}) |> seen_at(DateTime.utc_now())

      refute Models.retired?("test_provider", "never-heard-of-it")
    end

    test "nothing is retired while the catalog is too stale to trust" do
      old = DateTime.add(DateTime.utc_now(), -40, :day)
      model!(%{model_id: "a"}) |> seen_at(old)

      refute Models.retired?("test_provider", "a")
    end
  end

  describe "offerable_models/1" do
    test "hides a model the latest sync did not see" do
      now = DateTime.utc_now()

      current = model!(%{model_id: "still-here"}) |> seen_at(now)
      _retired = model!(%{model_id: "retired"}) |> seen_at(DateTime.add(now, -40, :day))

      ids = Models.offerable_models("test_provider") |> Enum.map(& &1.model_id)

      assert current.model_id in ids
      refute "retired" in ids
    end

    test "keeps everything when the catalog is too stale to trust" do
      # A sync that stopped running must not empty every picker. If the
      # freshest thing we know is old, we know nothing about what is retired
      # — and offering a stale list beats offering none.
      old = DateTime.add(DateTime.utc_now(), -40, :day)

      model!(%{model_id: "a"}) |> seen_at(old)
      model!(%{model_id: "b"}) |> seen_at(DateTime.add(old, -10, :day))

      ids = Models.offerable_models("test_provider") |> Enum.map(& &1.model_id)

      assert "a" in ids
      assert "b" in ids
    end

    test "keeps a model that has never been stamped" do
      # Rows written before the column existed, and any provider we upsert
      # ourselves rather than sync. Absence of evidence is not retirement.
      model!(%{model_id: "unstamped"})

      assert "unstamped" in (Models.offerable_models("test_provider") |> Enum.map(& &1.model_id))
    end

    test "pricing lookups still find a retired model" do
      # A model can be retired upstream while requests that name it are still
      # in flight, and their cost has to be computed from something.
      now = DateTime.utc_now()
      model!(%{model_id: "priced-current"}) |> seen_at(now)

      retired =
        model!(%{model_id: "priced-retired", input_price_per_million: Decimal.new("3.0")})
        |> seen_at(DateTime.add(now, -40, :day))

      assert Models.get_model_by_id("test_provider", retired.model_id)
    end
  end
end
