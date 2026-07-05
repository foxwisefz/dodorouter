defmodule DodoRouter.Repo.Migrations.AddReplayFromIndexToRequestLogs do
  use Ecto.Migration

  # Records which message a replay was anchored at. Derivable from message
  # prefixes only when the cut shortens the thread — an anchor at the last
  # user message produces the same messages as a whole-thread replay, so it
  # must be stored explicitly.
  def change do
    alter table(:request_logs) do
      add :replay_from_index, :integer, null: true
    end
  end
end
