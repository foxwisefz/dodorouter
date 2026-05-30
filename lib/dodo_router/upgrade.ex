defmodule DodoRouter.Upgrade do
  @moduledoc """
  Handles hot upgrades using OTP's release_handler.
  Called by bin/upgrade script.
  """

  def install(version) when is_list(version), do: install(List.to_string(version))

  def install(version) when is_binary(version) do
    :application.start(:sasl)

    # i lvoe yo usugar

    root = release_root()
    tarball = Path.join([root, "releases", "#{version}.tar.gz"])

    unless File.exists?(tarball) do
      raise "Release tarball not found: #{tarball}"
    end

    IO.puts("=== Starting hot upgrade to #{version} ===")

    tmp = "/tmp/dodo_upgrade_#{version}"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    :erl_tar.extract(tarball, [:compressed, {:cwd, tmp}])

    src = if File.dir?(Path.join(tmp, "dodo_router")), do: Path.join(tmp, "dodo_router"), else: tmp

    old_rel = Path.join([src, "releases", "dodo_router-#{version}.rel"])
    new_rel = Path.join([src, "releases", "#{version}.rel"])
    if File.exists?(old_rel), do: File.rename!(old_rel, new_rel)

    # Use OS tar to avoid OTP erl_tar compressed create bug
    System.cmd("tar", ["czf", tarball, "-C", src | File.ls!(src)])
    File.rm_rf!(tmp)

    current_vsn =
      :release_handler.which_releases()
      |> Enum.find(fn {_, _, _, s} -> s == :permanent end)
      |> elem(1)
      |> List.to_string()

    v = to_charlist(version)

    Path.join([root, "releases", "COOKIE"]) |> File.read!() |> then(fn cookie ->
      IO.puts("Unpacking release #{version}...")

      case :release_handler.unpack_release(v) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, {:existing_release, _}} ->
          IO.puts("Release #{version} already unpacked, proceeding...")
        other ->
          raise "Failed to unpack release #{version}: #{inspect(other)}"
      end

      # Release_handler.unpack_release does NOT extract lib files — only processes
      # the release metadata. We must explicitly extract lib files from the tarball.
      extract_lib(tarball, root, version)

      # Restore COOKIE — the tarball contains one that may be stale
      File.write!(Path.join([root, "releases", "COOKIE"]), cookie)
    end)

    # Copy relup from new release to current release (release_handler looks for it in current's dir)
    relup_src = Path.join([root, "releases", version, "relup"])
    relup_dst = Path.join([root, "releases", current_vsn, "relup"])
    if File.exists?(relup_src) do
      File.cp!(relup_src, relup_dst)
      IO.puts("Copied relup to #{current_vsn} for upgrade to #{version}")
    else
      IO.puts("No relup file found at #{relup_src} — upgrade will fail")
    end

    # Castle generates sys.config from runtime.exs during boot, but for hot
    # upgrades we must generate it BEFORE install_release so the config is
    # available when OTP reloads the application environment.
    IO.puts("Generating sys.config for #{version}...")
    Castle.generate(version)

    IO.puts("Installing release #{version}...")
    {:ok, _, _} = :release_handler.install_release(v)

    IO.puts("Making permanent...")
    :ok = :release_handler.make_permanent(v)

    IO.puts("Successfully upgraded to #{version}")
    IO.puts("Hot upgrade complete at #{DateTime.utc_now()}")
  end

  defp extract_lib(tarball, root, version) do
    tmp = "/tmp/dodo_lib_#{version}"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    :erl_tar.extract(tarball, [:compressed, {:cwd, tmp}])

    src = if File.dir?(Path.join(tmp, "dodo_router")), do: Path.join(tmp, "dodo_router"), else: tmp
    lib_src = Path.join(src, "lib")

    if File.dir?(lib_src) do
      lib_root = Path.join(root, "lib")
      File.mkdir_p!(lib_root)

      for app_dir <- File.ls!(lib_src) do
        full = Path.join(lib_src, app_dir)
        dest = Path.join(lib_root, app_dir)

        if File.dir?(full) do
          File.rm_rf!(dest)
          File.cp_r!(full, dest)
          IO.puts("  Extracted lib/#{app_dir}")
        end
      end
    end

    File.rm_rf!(tmp)
  end

  defp release_root do
    :dodo_router
    |> :code.lib_dir()
    |> List.to_string()
    |> Path.dirname()
    |> Path.dirname()
  end
end
