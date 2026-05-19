defmodule DodoRouter.Upgrade do
  @moduledoc """
  Handles hot code upgrades by manually extracting tarball and using release_handler.

  Usage:
      bin/dodo_router eval "DodoRouter.Upgrade.install('0.1.7')"
  """

  @compile {:no_warn_undefined, {:release_handler, :install_release, 1}}
  @compile {:no_warn_undefined, {:release_handler, :make_permanent, 1}}

  def install(version) do
    release_root = :code.root_dir() |> to_string()
    tarball = Path.join(release_root, "releases/dodo_router-#{version}.tar.gz")
    release_dir = Path.join(release_root, "releases/#{version}")

    unless File.exists?(tarball) do
      IO.puts("ERROR: Upgrade tarball not found: #{tarball}")
      System.halt(1)
    end

    # Clean up any previous failed attempt
    if File.exists?(release_dir) do
      IO.puts("Removing existing #{release_dir}...")
      File.rm_rf!(release_dir)
    end

    IO.puts("Extracting release #{version}...")
    File.mkdir_p!(release_dir)
    
    {_, 0} = System.cmd("tar", ["xzf", tarball, "-C", release_root])

    # Verify extraction succeeded
    rel_file = Path.join(release_dir, "dodo_router.rel")
    unless File.exists?(rel_file) do
      IO.puts("ERROR: Release description file not found: #{rel_file}")
      System.halt(1)
    end

    IO.puts("Installing release #{version}...")

    case :release_handler.install_release(String.to_charlist(version)) do
      {:ok, _, _} ->
        IO.puts("Making release #{version} permanent...")
        :ok = :release_handler.make_permanent(String.to_charlist(version))
        IO.puts("Hot upgrade to #{version} completed successfully!")

      error ->
        IO.puts("ERROR: Install failed: #{inspect(error)}")
        System.halt(1)
    end
  end
end
