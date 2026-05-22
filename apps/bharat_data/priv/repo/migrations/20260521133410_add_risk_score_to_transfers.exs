defmodule BharatData.Repo.Migrations.AddRiskScoreToTransfers do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :risk_score, :integer, default: 0, null: false
    end
  end
end
