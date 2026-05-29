defmodule DodoRouter.Upgrade do
  @moduledoc """
  Handles hot upgrades using OTP's release_handler.
  Called by bin/upgrade script.
  """

  def install(version) when is_list(version), do: install(List.to_string(version))

  def install(version) when is_binary(version) do
    :application.start(:sasl)

    root = release_root()
    tarball = Path.join([root, "releases", "#{version}.tar.gz"])

    unless File.exists?(tarball) do
      raise "Release tarball not found: #{tarball}"
    end

    IO.puts("Preparing release #{version}...")

    tmp = "/tmp/dodo_upgrade_#{version}"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    :erl_tar.extract(tarball, [:compressed, {:cwd, tmp}])

    src = if File.dir?(Path.join(tmp, "dodo_router")), do: Path.join(tmp, "dodo_router"), else: tmp

    old_rel = Path.join([src, "releases", "dodo_router-#{version}.rel"])
    new_rel = Path.join([src, "releases", "#{version}.rel"])
    if File.exists?(old_rel), do: File.rename!(old_rel, new_rel)

    :erl_tar.create(tarball, File.ls!(src), [:compressed, {:cwd, src}])
    File.rm_rf!(tmp)

    current_vsn =
      :release_handler.which_releases()
      |> Enum.find(fn {_, _, _, s} -> s == :permanent end)
      |> elem(1)
      |> List.to_string()

    relup_src = Path.join([root, "releases", version, "relup"])
    relup_dst = Path.join([root, "releases", current_vsn, "relup"])
    if File.exists?(relup_src) do
      File.cp!(relup_src, relup_dst)
      IO.puts("Copied relup #{current_vsn} -> #{version}")
    end

    v = to_charlist(version)

    IO.puts("Unpacking release #{version}...")
    :ok = :release_handler.unpack_release(v)

    IO.puts("Installing release #{version}...")
    {:ok, _, _} = :release_handler.install_release(v)

    IO.puts("Making permanent...")
    :ok = :release_handler.make_permanent(v)

    IO.puts("Successfully upgraded to #{version}")
    IO.puts("Hot upgrade complete at #{DateTime.utc_now()}")
  end

  defp release_root do
    :release_handler.which_releases()
    |> hd()
    |> elem(2)
    |> hd()
    |> List.to_string()
    |> Path.dirname()
    |> Path.dirname()
  end
end
