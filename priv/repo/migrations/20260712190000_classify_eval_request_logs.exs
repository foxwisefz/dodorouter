defmodule DodoRouter.Repo.Migrations.ClassifyEvalRequestLogs do
  use Ecto.Migration

  def up do
    alter table(:request_logs) do
      add :traffic_type, :string, null: false, default: "proxy"
    end

    create index(:request_logs, [:traffic_type])

    execute("""
    UPDATE request_logs AS rl
    SET traffic_type = CASE
      WHEN er.candidate_log_id = rl.id THEN 'evaluation_candidate'
      ELSE 'evaluation_judge'
    END
    FROM evaluation_runs AS er
    WHERE rl.id = er.candidate_log_id OR rl.id = er.judge_log_id
    """)
  end

  def down do
    drop index(:request_logs, [:traffic_type])

    alter table(:request_logs) do
      remove :traffic_type
    end
  end
end
