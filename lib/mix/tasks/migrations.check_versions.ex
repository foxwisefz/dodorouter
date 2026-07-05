defmodule Mix.Tasks.Migrations.CheckVersions do
  @shortdoc "Fails when two migration files share a version number"

  @moduledoc """
  Ecto tracks applied migrations by version integer alone — filenames and
  module names never enter into it. If two different migration files ever
  carry the same version (even in different releases), whichever reaches an
  environment second is silently treated as already run. This broke the
  0.1.86 deploy: production had recorded 20260704120000 for one migration,
  so a colliding one was skipped and a later index migration crashed on the
  missing column.

  Run automatically by `mix precommit`. Always create migrations with
  `mix ecto.gen.migration <name>` — real timestamps don't collide.
  """

  use Mix.Task

  @default_dir Path.join(["priv", "repo", "migrations"])

  @impl Mix.Task
  def run(args) do
    dir =
      case args do
        [dir | _rest] -> dir
        [] -> @default_dir
      end

    duplicates =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.group_by(&version_of/1)
      |> Enum.filter(fn {version, files} -> version != nil and length(files) > 1 end)

    case duplicates do
      [] ->
        :ok

      duplicates ->
        listing =
          Enum.map_join(duplicates, "\n", fn {version, files} ->
            "  #{version}:\n    " <> Enum.join(Enum.sort(files), "\n    ")
          end)

        Mix.raise("""
        Duplicate migration versions found. Ecto tracks migrations by version \
        number alone, so files sharing one silently skip each other in any \
        environment where the version is already recorded.

        #{listing}

        Renumber one of them — and prefer `mix ecto.gen.migration <name>`, \
        which stamps a collision-proof timestamp.\
        """)
    end
  end

  defp version_of(filename) do
    case Integer.parse(filename) do
      {version, _rest} -> version
      :error -> nil
    end
  end
end
