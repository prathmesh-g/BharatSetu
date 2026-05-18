defmodule BharatData.Repo.Migrations.UpgradeTransferEventsForProduction do
  use Ecto.Migration

  def change do
     alter table(:transfer_events) do
      add :from_state,     :string
      add :to_state,       :string
      add :actor,          :string
      add :chain_tx_hash,  :string
      add :block_number,   :bigint
  end
	create index(:transfer_events, [:transfer_id, :inserted_at])
	create index(:transfer_events, [:actor])
 end
end

