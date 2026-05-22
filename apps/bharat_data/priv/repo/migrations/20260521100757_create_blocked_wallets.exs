defmodule BharatData.Repo.Migrations.CreateBlockedWallets do
  use Ecto.Migration

  def change do
    create table(:blocked_wallets, primary_key: false) do
      add :id,             :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :wallet_address, :string, null: false
      add :reason,         :string, null: false   # "ofac_sdn_match" | "ofac_fallback_match"
      add :sdn_name,       :string                # matched entity name from OpenSanctions
      add :sdn_program,    :string                # e.g. "SDGT", "IRAN"
      add :transfer_id,    :binary_id             # nil if blocked before transfer created
      add :direction,      :string                # transfer direction if known
      add :screening_api,  :string                # "opensanctions" | "fallback_list"
      add :metadata,       :map, default: %{}     # raw API response snippet

      timestamps(updated_at: false)
    end

    create unique_index(:blocked_wallets, [:wallet_address])
    create index(:blocked_wallets, [:inserted_at])
  end
end
