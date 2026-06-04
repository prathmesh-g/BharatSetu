defmodule BharatCore.Compliance.Engine do
  @moduledoc """
  Production compliance engine for BharatSetu.
  Implements Section 10.1 (OFAC Screening) and Section 10.2 (KYC)
  from bharatsetu-production-v1.md
  """
  require Logger

  alias BharatData.BlockedWallets

  # Fallback hardcoded list if API is unavailable
  @ofac_blocklist_fallback MapSet.new([
    "0x7f268357a8c2552623316e2562d90e642bb538e5",
    "0xd882cfc20f52f2599d84b8e8d58c7fb62cfe344b",
    "0x901bb9583b24d97e995513c6778dc6888ab6870e",
    "0xa7e5d5a720f06526557c513402f2e6b5fa20b008"
  ])

  @opensanctions_url "https://api.opensanctions.org/match/default"

  @doc """
  Runs compliance gate for a single wallet before a transfer is created.
  Checks OFAC + KYC as per Section 10.1 and 10.2.

  Options:
    - transfer_id: UUID string — the transfer this screen is for (nil if pre-creation)
    - direction: "source" or "destination"

  Returns :ok or {:error, reason}
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, :ofac_blocked | :kyc_required}
 def check(wallet, opts \\ []) when is_binary(wallet) do
  normalized = String.downcase(wallet)

  # Layer 3 — skip compliance for trusted internal wallets
   if BharatCore.Compliance.TrustedWallets.trusted?(normalized) do
    Logger.debug("[Compliance] Trusted wallet skipped wallet=#{normalized}")
    :ok
   else
    # Layer 2 — check cache before hitting API
    case BharatCore.Compliance.WalletCache.get(normalized) do
      {:ok, :clear} ->
        Logger.debug("[Compliance] Cache hit :clear wallet=#{normalized}")
        :ok

      {:ok, {:blocked, reason}} ->
        Logger.warning("[Compliance] Cache hit :blocked wallet=#{normalized} reason=#{reason}")
        {:error, :ofac_blocked}

      :miss ->
        # Layer 1 — assign risk tier, run appropriate checks
        amount = Keyword.get(opts, :amount, Decimal.new(0))
        tier   = BharatCore.Compliance.RiskTier.assign(amount)
        checks = BharatCore.Compliance.RiskTier.checks_for(tier)
        Logger.info("[Compliance] wallet=#{normalized} tier=#{tier} checks=#{inspect(checks)}")

        result =
          with :ok <- check_ofac(normalized, opts),
               :ok <- check_kyc(wallet),
               :ok <- maybe_check_structuring(checks, wallet),
	       :ok <- maybe_check_cross_bridge(checks, wallet) do
            :ok
          end

        # Cache the result
        case result do
          :ok                      -> BharatCore.Compliance.WalletCache.put(normalized, :clear)
          {:error, :ofac_blocked}  -> BharatCore.Compliance.WalletCache.put(normalized, {:blocked, "ofac"})
          _                        -> :ok
        end

        result
    end
   end
  end

  @doc """
  Check both source and destination wallets.
  Per Section 10.1: both must be screened before transfer init.

  Options:
    - transfer_id: UUID string
  """
  @spec check_transfer(String.t(), String.t(), keyword()) ::
          :ok | {:error, :ofac_blocked | :kyc_required}
  def check_transfer(source_wallet, dest_wallet, opts \\ []) do
    with :ok <- check(source_wallet, Keyword.put(opts, :direction, "source")),
         :ok <- check(dest_wallet, Keyword.put(opts, :direction, "destination")) do
      :ok
    end
  end

  # ── OFAC Screening ────────────────────────────────────────────────────────

  defp check_ofac(wallet, opts) do
    case screen_via_api(wallet) do
      {:ok, :clear} ->
        Logger.debug("[Compliance] OFAC clear: #{wallet}")
        :ok

      {:ok, :blocked, sdn_name} ->
        Logger.warning("[Compliance] OFAC blocked via API: #{wallet} — matched: #{sdn_name}")
        persist_block(wallet, sdn_name, "opensanctions", opts)
        {:error, :ofac_blocked}

      {:error, reason} ->
        Logger.error("[Compliance] OFAC API failed: #{inspect(reason)} — falling back to local list")
        check_ofac_fallback(wallet, opts)
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
        results =
          get_in(body, ["responses", "wallet", "results"]) ||
            get_in(body, ["results", "wallet", "results"]) || []

        if results == [] do
          {:ok, :clear}
        else
          captions = results |> Enum.map(& &1["caption"]) |> Enum.join(", ")
          Logger.warning("[Compliance] OFAC match found for #{wallet}: #{captions}")
          {:ok, :blocked, captions}
        end

      {:ok, %{status: status}} ->
        {:error, {:api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_ofac_fallback(wallet, opts) do
    if MapSet.member?(@ofac_blocklist_fallback, wallet) do
      Logger.warning("[Compliance] OFAC blocked via fallback list: #{wallet}")
      persist_block(wallet, nil, "fallback_list", opts)
      {:error, :ofac_blocked}
    else
      :ok
    end
  end

  # ── DB Persistence ────────────────────────────────────────────────────────

  defp persist_block(wallet, sdn_name, screening_api, opts) do
    attrs = %{
      wallet_address: wallet,
      reason:         "OFAC SDN match",
      sdn_name:       sdn_name,
      transfer_id:    Keyword.get(opts, :transfer_id),
      direction:      Keyword.get(opts, :direction),
      screening_api:  screening_api,
      metadata:       %{screened_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    }

    case BlockedWallets.record(attrs) do
      {:ok, _} ->
        Logger.info("[Compliance] Blocked wallet persisted: #{wallet}")

      {:error, changeset} ->
        # Likely a unique_constraint violation — wallet already blocked, not fatal
        Logger.warning("[Compliance] BlockedWallets.record failed for #{wallet}: #{inspect(changeset.errors)}")
    end
  end

  # ── KYC ───────────────────────────────────────────────────────────────────

  # KYC vendor TBD per Section 10.2 — mock returns ok for all wallets
  defp check_kyc(_wallet), do: :ok

  defp maybe_check_structuring(checks, wallet) do
    if :structuring in checks do
      check_structuring(wallet)
    else
      :ok
    end
  end  
 
  defp maybe_check_cross_bridge(checks, wallet) do
    if :structuring in checks or :chainabuse in checks do
      case BharatCore.Compliance.CrossBridgeDetector.check(wallet) do
        {:ok, %{flagged: true, risk_score: score, reasons: reasons}} ->
          Logger.warning("[Compliance] CrossBridge flagged wallet=#{wallet} score=#{score} reasons=#{inspect(reasons)}")
          if score >= 60 do
            {:error, :cross_bridge_structuring}
          else
            # score 30-59 — log and allow, will feed into risk_score later
            :ok
          end
        {:ok, %{flagged: false}} -> :ok
        {:error, _}              -> :ok  # fail-open
      end
    else
      :ok
    end
  end


  defp check_structuring(wallet) do
    case BharatCore.Compliance.StructuringDetector.check(wallet) do
      {:ok, :clear}                 -> :ok
      {:ok, :flagged, count, total} ->
        require Logger
        Logger.warning("[Compliance] Structuring flagged wallet=#{wallet} count=#{count} total_usd=#{total}")
        {:error, :structuring_detected}
      {:error, reason} ->
        require Logger
        Logger.error("[Compliance] StructuringDetector error wallet=#{wallet} reason=#{inspect(reason)}")
        :ok
    end
  end
end
