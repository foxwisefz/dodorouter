defmodule DodoRouter.Repo.Migrations.AddFidelityChangesToRequestLogs do
  use Ecto.Migration

  # Everything the proxy removed or rewrote on this request: stripped client
  # headers with the policy reason, request-body fields dropped by a whitelist
  # conversion, and native response fields not passed back.
  #
  # Nullable with no default — migrations run through the OLD release during a
  # hot upgrade, so existing rows and in-flight inserts must not depend on this
  # column existing.
  def change do
    alter table(:request_logs) do
      add :fidelity_changes, {:array, :map}
    end
  end
end
