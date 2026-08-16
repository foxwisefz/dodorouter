defmodule DodoRouter.Repo.Migrations.CreateEvalMonitors do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # A monitor keeps a shipped downgrade honest: the same rubric and judge
    # keep scoring live answers after the routing change, so drift surfaces
    # as a score drop instead of a support ticket. New table + one nullable
    # column — hot-upgrade safe.
    create table(:eval_monitors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :router_id, references(:routers, type: :binary_id, on_delete: :delete_all), null: false

      add :evaluation_id, :binary_id, null: false
      add :change_event_id, :binary_id
      add :status, :text, null: false, default: "active"
      # The accepted benchmark's average (and spread) for the applied
      # model — what "as good as measured" means for this monitor.
      add :baseline_avg, :integer, null: false
      add :baseline_stddev, :integer
      add :target_model, :text
      add :sample_size, :integer, null: false, default: 3
      add :interval_hours, :integer, null: false, default: 24
      add :last_sampled_at, :utc_datetime_usec
      add :consecutive_drops, :integer, null: false, default: 0
      add :alerted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:eval_monitors, [:evaluation_id], concurrently: true)
    create index(:eval_monitors, [:router_id], concurrently: true)

    # nil = a benchmark run, exactly as every existing row reads; "monitor"
    # marks judge-only runs produced by a monitor sweep so benchmark
    # aggregates never mix them in.
    alter table(:evaluation_runs) do
      add :kind, :text, null: true
    end
  end
end
