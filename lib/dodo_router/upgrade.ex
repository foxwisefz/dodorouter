defmodule DodoRouter.Upgrade do
  @moduledoc """
  Handles hot code upgrades via Erlang's release_handler.

  Usage:
      bin/dodo_router eval "DodoRouter.Upgrade.install('0.1.1')"
  """

  def install(version) do
    release_root = :code.root_dir() |> to_string()
    tarball = Path.join(release_root, "releases/#{version}.tar.gz")

    unless File.exists?(tarball) do
      IO.puts("ERROR: Upgrade tarball not found: #{tarball}")
      System.halt(1)
    end

    IO.puts("Unpacking release #{version}...")

    case :release_handler.unpack_release(String.to_charlist(tarball)) do
      {:ok, ^version} ->
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

      error ->
        IO.puts("ERROR: Unpack failed: #{inspect(error)}")
        System.halt(1)
    end
  end
end
