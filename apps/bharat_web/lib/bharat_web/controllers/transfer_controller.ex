defmodule BharatWeb.TransferController do
  use BharatWeb, :controller

  alias BharatCore.Bridge.{TransferServer, TransferSupervisor}
  alias BharatData.{Transfers, Schemas.Transfer}

  def index(conn, _params) do
    wallet = conn.assigns.wallet
    transfers = Transfers.list_by_wallet(wallet)
    json(conn, %{data: Enum.map(transfers, &serialize/1)})
  end

  def audit_log(conn, %{"id" => id}) do
  wallet = conn.assigns.wallet
  case Transfers.get(id, wallet) do
    nil ->
      conn |> put_status(:not_found) |> json(%{error: "not found"})
    _transfer ->
      events = BharatData.TransferEvents.list_for_transfer(id)
      json(conn, %{data: events})
  end
 end

  def show(conn, %{"id" => id}) do
    wallet = conn.assigns.wallet

    case Transfers.get(id, wallet) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      transfer ->
        # Merge live FSM state if process is running
        live_state =
          case TransferServer.get_state(id) do
            {:ok, s} -> s.state
            _ -> transfer.state
          end

        json(conn, %{data: serialize(%{transfer | state: to_string(live_state)})})
    end
  end

  def create(conn, params) do
    wallet    = conn.assigns.wallet
    direction = params["direction"] || "amoy_to_sepolia"

    # Compliance gate — required for CBDC flows, advisory for EVM flows
   with :ok <- maybe_check_compliance(direction, wallet, params["destination_wallet"]) do
      do_create(conn, wallet, direction, params)
    else
        {:error, :ofac_blocked} ->
   	  # Log blocked attempt as per Section 10.1
	   Logger.warning("[Compliance] Transfer blocked by OFAC screening wallet=#{wallet}")
	   conn
	   |> put_status(:forbidden)
	   |> json(%{error: "ofac_blocked", message: "Wallet is on OFAC sanctions list. Transfer blocked."})
	{:error, reason} ->
	   conn |> put_status(:forbidden) |> json(%{error: to_string(reason)})
    end
  end

  defp do_create(conn, wallet, direction, params) do
    amount = parse_amount(params["amount"])
    if Decimal.compare(amount, Decimal.new(0)) != :gt do
      conn |> put_status(:unprocessable_entity) |> json(%{error: "amount must be positive"})
    else
      attrs = %{
        wallet:              wallet,
        token_address:       params["token_address"],
        amount:              amount,
        direction:           direction,
        compliance_status:   "approved",
        instruction_payload: params["instruction_payload"],
        asset_contract:      params["asset_contract"],
        asset_token_id:      params["asset_token_id"] && String.to_integer(params["asset_token_id"]),
        channel_id:          params["channel_id"],
        cross_chain_id:      params["cross_chain_id"],
        nft_metadata_uri:    params["nft_metadata_uri"],
        nft_metadata_hash:   params["nft_metadata_hash"]
      }

      require Logger
      Logger.info("[TransferController.create] wallet=#{wallet} token=#{attrs.token_address} amount=#{attrs.amount} direction=#{direction}")

      case TransferSupervisor.start_transfer(attrs) do
        {:ok, id} ->
          Logger.info("[TransferController.create] OK id=#{id}")
          conn
          |> put_status(:created)
          |> json(%{data: %{id: id, state: "init"}})

        {:error, reason} ->
          Logger.error("[TransferController.create] FAILED reason=#{inspect(reason)}")
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end
  end

  @cbdc_directions ~w(cbdc_to_stablecoin stablecoin_to_cbdc token_to_instruction asset_to_instruction
                      eth_to_sol sol_to_eth eth_nft_to_sol sol_nft_to_eth)

  defp maybe_check_compliance(direction, wallet, dest_wallet \\ nil)
  defp maybe_check_compliance(direction, wallet, dest_wallet) when direction in @cbdc_directions do
    BharatCore.Compliance.Engine.check_transfer(wallet, dest_wallet || wallet)
  end
  defp maybe_check_compliance(_direction, _wallet, _dest_wallet), do: :ok

  def confirm_lock(conn, %{"id" => id, "tx_hash" => tx_hash} = params) do
    wallet = conn.assigns.wallet
    cross_chain_id = params["cross_chain_id"]

    require Logger
    Logger.info("[TransferController.confirm_lock] id=#{id} wallet=#{wallet} tx=#{tx_hash} cross_chain_id=#{inspect(cross_chain_id)}")

    case Transfers.get(id, wallet) do
      nil ->
        Logger.error("[TransferController.confirm_lock] NOT FOUND id=#{id} wallet=#{wallet}")
        all = BharatData.Transfers.list_by_wallet(wallet)
        Logger.error("[TransferController.confirm_lock] DB has #{length(all)} transfers for wallet: #{Enum.map(all, & &1.id) |> inspect()}")
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      transfer ->
        Logger.info("[TransferController.confirm_lock] FOUND state=#{transfer.state}")
        if cross_chain_id do
          Transfers.update_state(id, transfer.state, %{cross_chain_id: cross_chain_id})
        end
        TransferServer.lock_submitted(id, tx_hash)
        json(conn, %{data: %{id: id, state: "locked"}})
    end
  end

  def cancel(conn, %{"id" => id}) do
    wallet = conn.assigns.wallet

    case Transfers.get(id, wallet) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      %{state: "init", lock_tx_hash: nil} ->
        Transfers.update_state(id, "failed", %{failure_reason: "cancelled by user"})
        json(conn, %{data: %{id: id, state: "failed"}})

      _ ->
        conn |> put_status(:conflict) |> json(%{error: "transfer cannot be cancelled after submission"})
    end
  end

  def retry(conn, %{"id" => id}) do
    wallet = conn.assigns.wallet

    case Transfers.get(id, wallet) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      %{state: "failed", failure_reason: reason} when not is_nil(reason) ->
	  # Re-screen on retry as per Section 10.1
       with :ok <- BharatCore.Compliance.Engine.check(wallet) do
        if String.contains?(reason, "relay") do
          case Transfers.reset_for_retry(id) do
            {:ok, :reset} -> json(conn, %{data: %{id: id, state: "confirmed"}})
            {:error, _}   -> conn |> put_status(:unprocessable_entity) |> json(%{error: "reset failed"})
          end
        else
          conn |> put_status(:conflict) |> json(%{error: "only relay failures can be retried"})
        end

      else
        {:error, :ofac_blocked} ->
          conn |> put_status(:forbidden) |> json(%{error: "ofac_blocked"})
        {:error, reason} ->
          conn |> put_status(:forbidden) |> json(%{error: to_string(reason)})
      end

      _ ->
        conn |> put_status(:conflict) |> json(%{error: "transfer is not in a retryable state"})
    end
  end

  defp serialize(%Transfer{} = t) do
    %{
      id:                  t.id,
      wallet:              t.wallet,
      token_address:       t.token_address,
      amount:              t.amount,
      nonce_hash:          t.nonce_hash,
      state:               t.state,
      direction:           t.direction,
      compliance_status:   t.compliance_status,
      source_chain:        t.source_chain,
      dest_chain:          t.dest_chain,
      transfer_type:       t.transfer_type,
      instruction_payload: t.instruction_payload,
      asset_contract:      t.asset_contract,
      asset_token_id:      t.asset_token_id,
      lock_tx_hash:        t.lock_tx_hash,
      mint_tx_hash:        t.mint_tx_hash,
      failure_reason:      t.failure_reason,
      channel_id:          Map.get(t, :channel_id),
      cross_chain_id:      Map.get(t, :cross_chain_id),
      solana_signature:    Map.get(t, :solana_signature),
      solana_mint_sig:     Map.get(t, :solana_mint_sig),
      nft_metadata_uri:    Map.get(t, :nft_metadata_uri),
      commit_tx_b:         Map.get(t, :commit_tx_b),
      rollback_reason:     Map.get(t, :rollback_reason),
      inserted_at:         t.inserted_at
    }
  end

  defp serialize(map), do: map

  defp parse_amount(nil), do: Decimal.new(0)
  defp parse_amount(n) when is_integer(n), do: Decimal.new(n)
  defp parse_amount(s) when is_binary(s), do: Decimal.new(s)
  defp parse_amount(f) when is_float(f), do: Decimal.from_float(f)
end
