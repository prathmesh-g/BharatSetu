defmodule BharatData.Transfers do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.{Transfer, TransferEvent}

  def create(attrs) do
    %Transfer{}
    |> Transfer.changeset(attrs)
    |> Repo.insert()
  end

  def get(id) do
    Repo.get(Transfer, id)
  end

  def get(id, wallet) do
    Repo.get_by(Transfer, id: id, wallet: wallet)
  end

  def list_by_wallet(wallet) do
    Transfer
    |> where([t], t.wallet == ^wallet)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def update_state(id, new_state, extra_attrs \\ %{}) do
    case get(id) do
      nil ->
        {:error, :not_found}

      transfer ->
        from_state = transfer.state
	attrs = Map.merge(%{state: new_state}, extra_attrs)
        result =
          transfer
          |> Transfer.changeset(attrs)
          |> Repo.update()

        with {:ok, updated} <- result do
          if from_state != new_state do 
            append_event(id, from_state,  new_state, extra_attrs)
	  end
          {:ok, updated}
        end
    end
  end

  def increment_relay_attempts(id) do
    {count, _} =
      Transfer
      |> where([t], t.id == ^id)
      |> Repo.update_all(inc: [relay_attempts: 1])

    count
  end

  # Returns confirmed transfers not yet picked up by relayer.
  # Relayer queries this to find work.
  def get_confirmed_pending_relay(limit \\ 50) do
    Transfer
    |> where([t], t.state == "confirmed" and t.relay_attempts < 3)
    |> order_by([t], asc: t.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # Returns eth_to_sol transfers in hub_recorded/validating state ready for Solana mint.
  # Bypasses the multi-sig consensus path; Solana MintBridge has its own idempotency.
  def get_eth_to_sol_pending_mint(limit \\ 50) do
    Transfer
    |> where([t], t.direction == "eth_to_sol" and t.state in ["hub_recorded", "validating", "confirmed"] and t.relay_attempts < 3)
    |> order_by([t], asc: t.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # Idempotency check: has this nonce_hash already been minted?
  def already_minted?(nonce_hash) do
    Transfer
    |> where([t], t.nonce_hash == ^nonce_hash and t.state in ["minted", "completed"])
    |> Repo.exists?()
  end

  # Mark init transfers with no tx hash older than cutoff_seconds as failed.
  # Called by InitTimeoutWorker every 2 min.
  def expire_stale_init_transfers(cutoff_seconds \\ 600) do
    cutoff = DateTime.add(DateTime.utc_now(), -cutoff_seconds, :second)
    now    = DateTime.utc_now()

    {count, _} =
      Transfer
      |> where([t], t.state == "init" and is_nil(t.lock_tx_hash) and t.inserted_at < ^cutoff)
      |> Repo.update_all(
        set: [
          state: "failed",
          failure_reason: "expired: no tx submitted within 10 minutes",
          updated_at: now
        ]
      )

    count
  end

  # Channel-aware queries

  def get_by_cross_chain_id(cross_chain_id) do
    Transfer |> where([t], t.cross_chain_id == ^cross_chain_id) |> Repo.one()
  end

  def get_hub_recorded(channel_id, limit \\ 50) do
    Transfer
    |> where([t], t.channel_id == ^channel_id and t.state == "hub_recorded")
    |> order_by([t], asc: t.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # Transfers past their timeout that are not yet completed/rolled_back.
  def get_timed_out do
    now = DateTime.utc_now()
    terminal = ["completed", "rolled_back", "failed"]
    Transfer
    |> where([t], not is_nil(t.timeout_at) and t.timeout_at < ^now and t.state not in ^terminal)
    |> Repo.all()
  end

  def mark_rolling_back(id, reason) do
    update_state(id, "rolling_back", %{rollback_reason: reason})
  end

  def mark_rolled_back(id, rollback_tx_a \\ nil, rollback_tx_b \\ nil) do
    update_state(id, "rolled_back", %{rollback_tx_a: rollback_tx_a, rollback_tx_b: rollback_tx_b})
  end

  def commit_a(id, commit_tx_a) do
    update_state(id, "committed_a", %{commit_tx_a: commit_tx_a})
  end

  def commit_b(id, commit_tx_b) do
    update_state(id, "committed_b", %{commit_tx_b: commit_tx_b})
  end

  def finalize(id, hub_state_hash) do
    update_state(id, "completed", %{hub_state_hash: hub_state_hash})
  end

  # Reset a relay-failed transfer back to confirmed so relayer retries.
  def reset_for_retry(id) do
    now = DateTime.utc_now()

    {count, _} =
      Transfer
      |> where([t], t.id == ^id and t.state == "failed")
      |> Repo.update_all(
        set: [
          state: "confirmed",
          relay_attempts: 0,
          failure_reason: nil,
          updated_at: now
        ]
      )

    if count > 0, do: {:ok, :reset}, else: {:error, :not_found}
  end

  defp append_event(transfer_id, from_state, to_state, metadata) do

    actor = cond do
      Map.has_key?(metadata, :actor)      -> to_string(metadata.actor)
      Map.has_key?(metadata, "actor")     -> metadata["actor"]
      to_state in ["locked", "init"]      -> "user"
      to_state in ["confirmed", "failed"] -> "indexer"
      to_state in ["minted", "completed"] -> "relayer"
      true                                -> "system"
    end

    %TransferEvent{}
    |> TransferEvent.changeset(%{
      transfer_id:   transfer_id,
      from_state:    from_state,
      to_state:      to_state,
      actor:         actor,
      chain_tx_hash: metadata[:lock_tx_hash] || metadata[:mint_tx_hash] || metadata["lock_tx_hash"] || metadata["mint_tx_hash"],
      block_number:  metadata[:lock_block] || metadata["lock_block"],
      state:         to_state,
      metadata:      metadata
    })
    |> Repo.insert!()
  end
end
