defmodule BharatCore.Indexer.SepoliaIndexer do
  @moduledoc """
  Sepolia event indexer.
  Polls Sepolia every 3s for:
  - TokensBurned (MintBridge)  → Sepolia→Amoy return flow
  - TokenLocked  (EthVault)    → ETH→SOL channel flow
  """

  use GenServer
  require Logger

  alias BharatCore.Indexer.EventParser
  alias BharatCore.Bridge.TransferServer
  alias BharatData.{Transfers, IndexerCheckpoints}
  alias BharatAdapters.Blockchain.Contract

  defp resolve_transfer_id_for_eth_vault(event) do
    # crossChainId is keccak256(transferId+nonce), stored in DB as cross_chain_id
    case Transfers.get_by_cross_chain_id(event.cross_chain_id) do
      nil ->
        Logger.warning("[SepoliaIndexer] no transfer found for cross_chain_id=#{event.cross_chain_id}")
        nil
      t ->
        t.id
    end
  end

  @confirmation_depth Application.compile_env(:bharat_core, :confirmation_depth, 3)
  @backfill_batch_size 1000
  @poll_interval_ms 3_000
  @chain "sepolia"

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :start)
    {:ok, %{pending: %{}, current_block: 0}}
  end

  @impl true
  def handle_info(:start, state) do
    state = run_backfill(state)
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_new_blocks(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Poll ──────────────────────────────────────────────────────────────────

  defp poll_new_blocks(state) do
    case Contract.sepolia_block_number() do
      {:ok, latest} when latest > state.current_block ->
        from = state.current_block + 1
        to   = min(latest, from + 1000 - 1)

        state =
          case Contract.get_sepolia_logs(from, to) do
            {:ok, logs} ->
              Enum.reduce(logs, state, fn raw_log, acc ->
                case EventParser.parse(raw_log) do
                  {:tokens_burned, event} ->
                    Logger.debug("[SepoliaIndexer] TokensBurned block=#{event.block_number} transfer=#{event.transfer_id}")
                    put_in(acc.pending[{event.nonce_hash, event.tx_hash}], {event, event.block_number})
                  _ -> acc
                end
              end)
            {:error, reason} ->
              Logger.error("[SepoliaIndexer] MintBridge get_logs #{from}..#{to} failed: #{inspect(reason)}")
              state
          end

        # Also poll EthVault for ETH→SOL locks
        state =
          case Contract.get_eth_vault_logs(from, to) do
            {:ok, logs} ->
              Enum.reduce(logs, state, fn raw_log, acc ->
                case EventParser.parse(raw_log) do
                  {:eth_vault_locked, event} ->
                    Logger.info("[SepoliaIndexer] EthVault TokenLocked block=#{event.block_number} transfer=#{event.transfer_id} amount=#{event.amount}")
                    put_in(acc.pending[{event.transfer_id, event.tx_hash}], {event, event.block_number})
                  _ -> acc
                end
              end)
            {:error, reason} ->
              Logger.error("[SepoliaIndexer] EthVault get_logs #{from}..#{to} failed: #{inspect(reason)}")
              state
          end

        state = %{state | current_block: to}
        state = promote_confirmed(state, to)
        IndexerCheckpoints.update_last_block(to, @chain)
        state

      {:ok, _same} -> state

      {:error, reason} ->
        Logger.error("Sepolia eth_blockNumber failed: #{inspect(reason)}")
        state
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  # ── Backfill ──────────────────────────────────────────────────────────────

  defp run_backfill(state) do
    case Contract.sepolia_block_number() do
      {:ok, current_block} ->
        last_saved = IndexerCheckpoints.get_last_block(@chain)

        from_block =
          if last_saved == 0,
            do: max(0, current_block - 1000),
            else: last_saved + 1

        if from_block < current_block do
          Logger.info("Sepolia indexer backfill: blocks #{from_block}..#{current_block}")
          backfill_range(from_block, current_block)
          IndexerCheckpoints.update_last_block(current_block, @chain)
        end

        %{state | current_block: current_block}

      {:error, reason} ->
        Logger.error("Sepolia backfill: could not get block number: #{inspect(reason)}")
        state
    end
  end

  defp backfill_range(from, to) when from > to, do: :ok

  defp backfill_range(from, to) do
    batch_to = min(from + @backfill_batch_size - 1, to)

    case Contract.get_sepolia_logs(from, batch_to) do
      {:ok, logs} ->
        Enum.each(logs, fn raw_log ->
          case EventParser.parse(raw_log) do
            {:tokens_burned, event} ->
              Logger.info("[SepoliaIndexer] backfill burn transfer=#{event.transfer_id}")
              TransferServer.on_confirmed(event.transfer_id, event.block_number)
            _ -> :skip
          end
        end)
      {:error, reason} ->
        Logger.error("[SepoliaIndexer] backfill MintBridge #{from}..#{batch_to} failed: #{inspect(reason)}")
    end

    case Contract.get_eth_vault_logs(from, batch_to) do
      {:ok, logs} ->
        Enum.each(logs, fn raw_log ->
          case EventParser.parse(raw_log) do
            {:eth_vault_locked, event} ->
              case resolve_transfer_id_for_eth_vault(event) do
                nil -> :skip
                transfer_id ->
                  Logger.info("[SepoliaIndexer] backfill eth_vault_locked transfer=#{transfer_id} dest=#{event.dest_wallet}")
                  if event.dest_wallet do
                    Transfers.update_state(transfer_id, "locked", %{
                      lock_tx_hash: event.tx_hash,
                      instruction_payload: event.dest_wallet
                    })
                  end
                  TransferServer.lock_submitted(transfer_id, event.tx_hash)
                  TransferServer.on_confirmed(transfer_id, event.block_number)
              end
            _ -> :skip
          end
        end)
      {:error, reason} ->
        Logger.error("[SepoliaIndexer] backfill EthVault #{from}..#{batch_to} failed: #{inspect(reason)}")
    end

    backfill_range(batch_to + 1, to)
  end

  # ── Confirmation depth ────────────────────────────────────────────────────

  defp promote_confirmed(state, current_block) do
    {to_confirm, still_pending} =
      Enum.split_with(state.pending, fn {_k, {_event, block}} ->
        current_block - block >= @confirmation_depth
      end)

    Enum.each(to_confirm, fn {_k, {event, block}} ->
      cond do
        Map.has_key?(event, :cross_chain_id) ->
          # ETH→SOL: look up DB transfer by cross_chain_id (keccak256 key stored at confirmLock)
          case resolve_transfer_id_for_eth_vault(event) do
            nil -> :skip
            transfer_id ->
              Logger.info("[SepoliaIndexer] EthVault lock confirmed transfer=#{transfer_id} block=#{block} dest=#{event.dest_wallet}")
              # Store dest Solana wallet in instruction_payload so relayer can mint to correct address
              if event.dest_wallet do
                Transfers.update_state(transfer_id, "locked", %{
                  lock_tx_hash: event.tx_hash,
                  instruction_payload: event.dest_wallet
                })
              end
              TransferServer.lock_submitted(transfer_id, event.tx_hash)
              TransferServer.on_confirmed(transfer_id, block)
          end

        true ->
          # Sepolia→Amoy: MintBridge burn confirmed
          Logger.info("[SepoliaIndexer] MintBridge burn confirmed transfer=#{event.transfer_id} block=#{block}")
          TransferServer.on_confirmed(event.transfer_id, block)
      end
    end)

    %{state | pending: Map.new(still_pending)}
  end
end
