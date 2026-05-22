defmodule BharatData.Schemas.Transfer do
  use Ecto.Schema
  import Ecto.Changeset

  # Extended FSM: channel-aware states added
  @valid_states ~w(
    init locked confirmed minted completed failed
    hub_recorded validating consensus_b minting_b committed_b committed_a
    rolling_back rolled_back
  )
  @valid_directions ~w(
    amoy_to_sepolia sepolia_to_amoy
    cbdc_to_stablecoin stablecoin_to_cbdc
    token_to_instruction asset_to_instruction
    eth_to_sol sol_to_eth
    eth_nft_to_sol sol_nft_to_eth
  )
  @valid_compliance_statuses ~w(approved rejected)
  @valid_transfer_types ~w(token_to_token token_to_instruction asset_to_instruction nft_to_nft)
  @valid_token_versions ~w(original wrapped)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "transfers" do
    field :wallet,               :string
    field :token_address,        :string
    field :amount,               :decimal
    field :nonce_hash,           :string
    field :state,                :string, default: "init"
    field :direction,            :string, default: "amoy_to_sepolia"
    field :compliance_status,    :string, default: "approved"
    field :source_chain,         :string, default: "amoy"
    field :dest_chain,           :string, default: "sepolia"
    field :transfer_type,        :string, default: "token_to_token"
    field :instruction_payload,  :string
    field :asset_contract,       :string
    field :asset_token_id,       :integer
    field :lock_tx_hash,         :string
    field :lock_block,           :integer
    field :mint_tx_hash,         :string
    field :failure_reason,       :string
    field :relay_attempts,       :integer, default: 0

    # Channel fields
    field :channel_id,           :string
    field :cross_chain_id,       :string
    field :token_version,        :string, default: "original"
    field :wrapped_token_ref,    :string

    # Solana tx refs
    field :solana_signature,     :string
    field :solana_mint_sig,      :string

    # NFT
    field :nft_metadata_uri,     :string
    field :nft_metadata_hash,    :string

    # Commit / rollback
    field :commit_tx_a,          :string
    field :commit_tx_b,          :string
    field :hub_state_hash,       :string
    field :timeout_at,           :utc_datetime
    field :rollback_reason,      :string
    field :rollback_tx_a,        :string
    field :rollback_tx_b,        :string
    field :risk_score,           :integer, default: 0

    timestamps()
  end

  @all_fields [
    :id, :wallet, :token_address, :amount, :nonce_hash, :state, :direction,
    :compliance_status, :source_chain, :dest_chain,
    :transfer_type, :instruction_payload, :asset_contract, :asset_token_id,
    :lock_tx_hash, :lock_block, :mint_tx_hash, :failure_reason, :relay_attempts,
    :channel_id, :cross_chain_id, :token_version, :wrapped_token_ref,
    :solana_signature, :solana_mint_sig,
    :nft_metadata_uri, :nft_metadata_hash,
    :commit_tx_a, :commit_tx_b, :hub_state_hash,
    :timeout_at, :rollback_reason, :rollback_tx_a, :rollback_tx_b, :risk_score,
  ]

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, @all_fields)
    |> validate_required([:wallet, :amount, :nonce_hash])
    |> validate_inclusion(:state, @valid_states)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:compliance_status, @valid_compliance_statuses)
    |> validate_inclusion(:transfer_type, @valid_transfer_types)
    |> validate_inclusion(:token_version, @valid_token_versions)
    |> unique_constraint(:nonce_hash)
  end

  def valid_states, do: @valid_states
  def valid_directions, do: @valid_directions
  def valid_transfer_types, do: @valid_transfer_types
  def valid_token_versions, do: @valid_token_versions
end
