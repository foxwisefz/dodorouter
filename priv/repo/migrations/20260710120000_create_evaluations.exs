defmodule DodoRouter.Repo.Migrations.CreateEvaluations do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:evaluations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_log_id, references(:request_logs, type: :binary_id, on_delete: :delete_all)
      add :evaluated_by_id, references(:users, type: :binary_id, on_delete: :delete_all)
      timestamps(type: :utc_datetime)
    end

    alter table(:evaluations) do
      add_if_not_exists :name, :string
      add_if_not_exists :criteria, :text
      add_if_not_exists :good_examples, :text
      add_if_not_exists :bad_examples, :text
      add_if_not_exists :judge_model, :string
      add_if_not_exists :rating_type, :string, default: "good"

      add_if_not_exists :judge_provider_key_id,
                        references(:provider_keys, type: :binary_id, on_delete: :restrict)
    end

    create_if_not_exists index(:evaluations, [:evaluated_by_id, :inserted_at])
    create_if_not_exists index(:evaluations, [:request_log_id])

    create table(:evaluation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "pending"
      add :score, :integer
      add :max_score, :integer, null: false, default: 100
      add :passed, :boolean
      add :summary, :text
      add :criterion_scores, :map, null: false, default: %{}
      add :issues, {:array, :string}, null: false, default: []
      add :raw_judge_response, :text
      add :error, :text
      add :duration_ms, :integer
      add :judge_prompt_version, :string, null: false, default: "v1"

      add :evaluation_id, references(:evaluations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :judge_log_id, references(:request_logs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:evaluation_runs, [:evaluation_id, :inserted_at])
  end
end
