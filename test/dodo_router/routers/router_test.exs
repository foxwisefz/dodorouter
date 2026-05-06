defmodule DodoRouter.Routers.RouterTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Routers.Router

  describe "changeset/2 slug auto-generation" do
    test "derives slug from name when slug is blank" do
      changeset = Router.changeset(%Router{}, %{name: "My Cool Router"})
      assert Ecto.Changeset.get_field(changeset, :slug) == "my-cool-router"
    end

    test "preserves explicit slug when provided" do
      changeset = Router.changeset(%Router{}, %{name: "My Router", slug: "custom-slug"})
      assert Ecto.Changeset.get_field(changeset, :slug) == "custom-slug"
    end

    test "strips special characters from name" do
      changeset = Router.changeset(%Router{}, %{name: "Router #1 (Production)"})
      assert Ecto.Changeset.get_field(changeset, :slug) == "router-1-production"
    end

    test "strips underscores from name" do
      changeset = Router.changeset(%Router{}, %{name: "my_cool_router"})
      assert Ecto.Changeset.get_field(changeset, :slug) == "mycoolrouter"
    end

    test "does not set slug when name is empty" do
      changeset = Router.changeset(%Router{}, %{name: ""})
      assert Ecto.Changeset.get_field(changeset, :slug) == nil
    end

    test "trims leading and trailing dashes" do
      changeset = Router.changeset(%Router{}, %{name: "--My Router--"})
      assert Ecto.Changeset.get_field(changeset, :slug) == "my-router"
    end

    test "validates required name" do
      changeset = Router.changeset(%Router{}, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates slug format when explicitly set" do
      changeset = Router.changeset(%Router{}, %{name: "Test", slug: "INVALID"})
      assert %{slug: ["must be lowercase alphanumeric with dashes"]} = errors_on(changeset)
    end

    test "validates slug minimum length" do
      changeset = Router.changeset(%Router{}, %{name: "Test", slug: "ab"})
      assert %{slug: ["should be at least 3 character(s)"]} = errors_on(changeset)
    end
  end
end
