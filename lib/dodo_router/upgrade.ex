defmodule DodoRouter.Upgrade do
  @moduledoc """
  Handles hot upgrades using OTP's release_handler.
  Called by bin/upgrade script.
  """

  def install(version) when is_binary(version) do
    v = to_charlist(version)

    :application.start(:sasl)

    IO.puts("Unpacking release #{version}...")
    :ok = :release_handler.unpack_release(v)

    IO.puts("Checking install...")
    {:ok, _, _} = :release_handler.check_install_release(v)

    IO.puts("Installing release #{version}...")
    {:ok, _, _} = :release_handler.install_release(v)

    IO.puts("Making permanent...")
    :ok = :release_handler.make_permanent(v)

    IO.puts("Successfully upgraded to #{version}")
  end
end
