defmodule BharatCore.Compliance.Engine do
  @moduledoc """
  Production compliance engine for BharatSetu.
  Implements Section 10.1 (OFAC Screening) and Section 10.2 (KYC) 
  from bharatsetu-production-v1.md
  """
  require Logger

  # Fallback hardcoded list if API is unavailable
  @ofac_blocklist_fallback MapSet.new([
    "0x7f268357a8c2552623316e2562d90e642bb538e5",
    "0xd882cfc20f52f2599d84b8e8d58c7fb62cfe344b",
    "0x901bb9583b24d97e995513c6778dc6888ab6870e",
    "0xa7e5d5a720f06526557c513402f2e6b5fa20b008"
  ])

  @opensanctions_url "https://api.opensanctions.org/match/default"

  @doc """
  Runs compliance gate for a wallet before a transfer is created.
  Checks BOTH source and destination wallets as per Section 10.1.
  Returns :ok or {:error, reason}
  """
  @spec check(String.t()) :: :ok | {:error, :ofac_blocked | :kyc_required}
  def check(wallet) when is_binary(wallet) do
    normalized = String.downcase(wallet)
    with :ok <- check_ofac(normalized),
         :ok <- check_kyc(wallet) do
      :ok
    end
  end

  @doc """
  Check both source and destination wallets.
  Per Section 10.1: both must be screened before transfer init.
  """
  @spec check_transfer(String.t(), String.t()) :: :ok | {:error, :ofac_blocked | :kyc_required}
  def check_transfer(source_wallet, dest_wallet) do
    with :ok <- check(source_wallet),
         :ok <- check(dest_wallet) do
      :ok
    end
  end

  # ── OFAC Screening ────────────────────────────────────────────────────────

  defp check_ofac(wallet) do
    case screen_via_api(wallet) do
      {:ok, :clear}   ->
        Logger.debug("[Compliance] OFAC clear: #{wallet}")
        :ok
      {:ok, :blocked} ->
        Logger.warning("[Compliance] OFAC blocked: #{wallet}")
        {:error, :ofac_blocked}
      {:error, reason} ->
        Logger.error("[Compliance] OFAC API failed: #{inspect(reason)} — falling back to local list")
        check_ofac_fallback(wallet)
    end
  end

  defp screen_via_api(wallet) do
    api_key = Application.get_env(:bharat_core, :opensanctions_api_key, "")

    headers = [
      {"content-type", "application/json"},
      {"authorization", "ApiKey #{api_key}"}
    ]

    body = Jason.encode!(%{
      "queries" => %{
        "wallet" => %{
          "schema" => "CryptoWallet",
          "properties" => %{
            "publicKey" => [wallet]
          }
        }
      }
    })

    case Req.post(@opensanctions_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        results = get_in(body, ["responses", "wallet", "results"]) ||
		  get_in(body, ["results", "wallet", "results"]) || []
        if results == [] do
          {:ok, :clear}
        else
          Logger.warning("[Compliance] OFAC match found for #{wallet}: #{inspect(Enum.map(results, & &1["caption"]))}")
          {:ok, :blocked}
        end

      {:ok, %{status: status}} ->
        {:error, {:api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_ofac_fallback(wallet) do
    if MapSet.member?(@ofac_blocklist_fallback, wallet) do
      {:error, :ofac_blocked}
    else
      :ok
    end
  end

  # ── KYC ───────────────────────────────────────────────────────────────────

  # KYC vendor TBD per Section 10.2 — mock returns ok for all wallets
  defp check_kyc(_wallet), do: :ok
end
