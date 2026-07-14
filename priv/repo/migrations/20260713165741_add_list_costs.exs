defmodule DodoRouter.Repo.Migrations.AddListCosts do
  use Ecto.Migration

  def change do
    # What the request would cost at pay-as-you-go API list prices.
    # Equals estimated_cost_usd for metered keys; the real comparison
    # number for plan/subscription keys whose estimated cost is $0.
    # Nullable: nil = unknown (no metered catalog row, or pre-feature row);
    # old code inserting during a hot upgrade leaves it nil.
    alter table(:request_logs) do
      add :list_cost_usd, :decimal
    end

    alter table(:evaluation_runs) do
      add :candidate_list_cost_usd, :decimal
      add :judge_list_cost_usd, :decimal
    end
  end
end
