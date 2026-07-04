defmodule DodoRouter.SecretsTest do
  use ExUnit.Case, async: true

  describe "secrets cache table" do
    test "exists at application boot and is owned by a long-lived process" do
      # A lazily-created named ETS table is owned by whatever transient
      # process touched it first and is destroyed when that process exits —
      # taking every cached secret (and other tests' seeded keys) with it.
      # The application must create it at boot instead, so it exists here
      # even though nothing in this test file ever wrote to it.
      table = :ets.whereis(:dodo_secrets_cache)
      assert table != :undefined, "secrets cache table was not created at application boot"

      owner = :ets.info(table, :owner)
      assert is_pid(owner)
      assert Process.alive?(owner)
      refute owner == self()
    end
  end
end
