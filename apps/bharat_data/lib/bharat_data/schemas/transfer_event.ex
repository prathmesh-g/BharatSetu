defmodule BharatData.Schemas.TransferEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "transfer_events" do
    field :transfer_id, :binary_id
    field :from_state,    :string
    field :to_state,      :string
    field :actor,         :string
    field :chain_tx_hash, :string
    field :block_number,  :integer
    field :state,       :string
    field :metadata,    :map, default: %{}
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:transfer_id, :from_state, :to_state, :actor,
                    :chain_tx_hash, :block_number, :state, :metadata])
    |> validate_required([:transfer_id, :to_state, :actor])
  end
end
