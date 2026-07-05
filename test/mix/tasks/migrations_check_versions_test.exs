defmodule Mix.Tasks.Migrations.CheckVersionsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Migrations.CheckVersions

  setup do
    dir =
      Path.join(System.tmp_dir!(), "migration_versions_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  test "passes when all versions are unique", %{dir: dir} do
    File.write!(Path.join(dir, "20260701120000_add_a.exs"), "")
    File.write!(Path.join(dir, "20260702093012_add_b.exs"), "")

    assert CheckVersions.run([dir]) == :ok
  end

  test "fails when two files share a version", %{dir: dir} do
    File.write!(Path.join(dir, "20260704120000_add_a.exs"), "")
    File.write!(Path.join(dir, "20260704120000_add_b.exs"), "")

    assert_raise Mix.Error, ~r/20260704120000/, fn ->
      CheckVersions.run([dir])
    end
  end

  test "ignores non-migration files", %{dir: dir} do
    File.write!(Path.join(dir, ".formatter.exs"), "")
    File.write!(Path.join(dir, "20260701120000_add_a.exs"), "")

    assert CheckVersions.run([dir]) == :ok
  end

  test "passes on the project's real migrations directory" do
    assert CheckVersions.run([]) == :ok
  end
end
