defmodule BharatData.Schemas.BlockedWallet do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "blocked_wallets" do
    field :wallet_address, :string
    field :reason,         :string
    field :sdn_name,       :string
    field :sdn_program,    :string
    field :transfer_id,    :binary_id
    field :direction,      :string
    field :screening_api,  :string
    field :metadata,       :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(blocked_wallet, attrs) do
    blocked_wallet
    |> cast(attrs, [:wallet_address, :reason, :sdn_name, :sdn_program,
                    :transfer_id, :direction, :screening_api, :metadata])
    |> validate_required([:wallet_address, :reason])
    |> unique_constraint(:wallet_address)
  end
end
