defmodule BharatCore.Compliance.WalletHistory do
  @moduledoc """
  Public API for fetching and analysing wallet transaction history.
  Used by compliance engine and exposed via REST for internal tooling.
  """
  require Logger
  alias BharatCore.Compliance.{AlchemyClient, BridgeRegistry}

  @doc """
  Returns full transaction history for a wallet across all chains.
  Enriches each transfer with bridge metadata.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(wallet) do
    case AlchemyClient.fetch_all_chains(wallet) do
      {:ok, chain_transfers} ->
        enriched = enrich(chain_transfers, wallet)
        {:ok, enriched}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp enrich(chain_transfers, wallet) do
    chains =
      chain_transfers
      |> Enum.map(fn {chain, transfers} ->
        enriched =
          Enum.map(transfers, fn t ->
            Map.merge(t, %{
              is_bridge_tx:    BridgeRegistry.known_bridge?(t.to, chain),
              is_bharatsetu:   BridgeRegistry.bharatsetu?(t.to),
              direction:       if(String.downcase(t.from) == String.downcase(wallet), do: "out", else: "in"),
            })
          end)

        bridge_txs    = Enum.filter(enriched, & &1.is_bridge_tx and not &1.is_bharatsetu)
        bridge_volume = bridge_txs |> Enum.map(& &1.value) |> Enum.sum()
        total_volume  = enriched   |> Enum.map(& &1.value) |> Enum.sum()

        {chain, %{
          transfers:     enriched,
          count:         length(enriched),
          total_volume:  Float.round(total_volume * 1.0, 4),
          bridge_count:  length(bridge_txs),
          bridge_volume: Float.round(bridge_volume * 1.0, 4),
        }}
      end)
      |> Map.new()

    %{
      wallet:        wallet,
      chains:        chains,
      total_count:   chains |> Map.values() |> Enum.map(& &1.count)         |> Enum.sum(),
      total_volume:  chains |> Map.values() |> Enum.map(& &1.total_volume)  |> Enum.sum(),
      bridge_count:  chains |> Map.values() |> Enum.map(& &1.bridge_count)  |> Enum.sum(),
      bridge_volume: chains |> Map.values() |> Enum.map(& &1.bridge_volume) |> Enum.sum(),
    }
  end
end
