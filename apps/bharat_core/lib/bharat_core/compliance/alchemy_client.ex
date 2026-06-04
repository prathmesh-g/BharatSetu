defmodule BharatCore.Compliance.AlchemyClient do
  @moduledoc """
  Fetches wallet transaction history via Alchemy getAssetTransfers API.
  Supports multiple chains via a chain -> URL mapping.
  Used for cross-bridge structuring detection.
  """
  require Logger

  @chain_urls %{
    polygon: "https://polygon-amoy.g.alchemy.com/v2/",
    eth:     "https://eth-sepolia.g.alchemy.com/v2/"
  }

  @type transfer :: %{
    from:  String.t(),
    to:    String.t(),
    value: float(),
    asset: String.t(),
    hash:  String.t(),
    block: String.t()
  }

  @doc """
  Fetch asset transfers FROM a wallet in the last 24h across all configured chains.
  Returns {:ok, %{polygon: [...], eth: [...]}} | {:error, reason}
  """
  @spec fetch_all_chains(String.t()) ::
    {:ok, %{atom() => [transfer()]}} | {:error, term()}
  def fetch_all_chains(wallet) do
    keys = chain_keys()

    results =
      @chain_urls
      |> Enum.map(fn {chain, base_url} ->
        key = Map.get(keys, chain)
        if key do
          case get_asset_transfers(wallet, base_url <> key) do
            {:ok, transfers} -> {chain, transfers}
            {:error, _}      -> {chain, []}  # fail-open per chain
          end
        else
          {chain, []}
        end
      end)
      |> Map.new()

    {:ok, results}
  end

  @doc """
  Fetch transfers for a single chain.
  """
  @spec fetch_chain(String.t(), atom()) :: {:ok, [transfer()]} | {:error, term()}
  def fetch_chain(wallet, chain) do
    keys     = chain_keys()
    base_url = Map.get(@chain_urls, chain)
    key      = Map.get(keys, chain)

    cond do
      is_nil(base_url) -> {:error, :unknown_chain}
      is_nil(key)      -> {:error, :no_api_key}
      true             -> get_asset_transfers(wallet, base_url <> key)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp chain_keys do
    %{
      polygon: Application.get_env(:bharat_core, :alchemy_polygon_key),
      eth:     Application.get_env(:bharat_core, :alchemy_eth_key)
    }
  end

  defp get_asset_transfers(wallet, url) do
    payload = %{
      "jsonrpc" => "2.0",
      "id"      => 1,
      "method"  => "alchemy_getAssetTransfers",
      "params"  => [%{
        "fromBlock"        => "0x0",
        "toBlock"          => "latest",
        "fromAddress"      => wallet,
        "category"         => ["erc20", "external"],
        "withMetadata"     => true,
        "excludeZeroValue" => true,
        "maxCount"         => "0x64"
      }]
    }

    case Req.post(url, json: payload, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"result" => %{"transfers" => transfers}}}} ->
        {:ok, parse_transfers(transfers)}

      {:ok, %{status: 200, body: %{"error" => err}}} ->
        Logger.warning("[AlchemyClient] API error chain=#{url} #{inspect(err)}")
        {:error, err}

      {:ok, %{status: status}} ->
        Logger.warning("[AlchemyClient] HTTP #{status}")
        {:error, "http_#{status}"}

      {:error, reason} ->
        Logger.error("[AlchemyClient] Request failed #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_transfers(transfers) do
    transfers
    |> Enum.map(fn t ->
      %{
        from:  String.downcase(t["from"] || ""),
        to:    String.downcase(t["to"] || ""),
        value: t["value"] || 0.0,
        asset: t["asset"] || "",
        hash:  t["hash"] || "",
        block: t["metadata"]["blockTimestamp"] || ""
      }
    end)
    |> filter_last_24h()
  end

  defp filter_last_24h(transfers) do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)
    Enum.filter(transfers, fn t ->
      case DateTime.from_iso8601(t.block) do
        {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :gt
        _            -> false
      end
    end)
  end
end
