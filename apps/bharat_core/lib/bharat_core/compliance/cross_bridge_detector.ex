defmodule BharatCore.Compliance.CrossBridgeDetector do
  @moduledoc """
  Detects cross-bridge structuring by analyzing wallet transaction history
  across multiple chains via Alchemy API.

  Checks:
  1. Cross-bridge volume in 24h across all known bridges
  2. Velocity fingerprinting (time gaps, round numbers, wallet age)
  3. Fan-out / fan-in patterns
  4. Returns a feature vector (ML-ready) + risk score contribution
  """
  require Logger

  alias BharatCore.Compliance.{AlchemyClient, BridgeRegistry}

  @usd_threshold          10_000.0
  @bridge_count_threshold 3        # interactions with 3+ different bridges = suspicious
  @round_number_threshold 0.4      # >40% round-number txns = suspicious
  @min_gap_threshold      300      # <5 min avg gap between txns = suspicious

  @type feature_vector :: %{
    own_transfer_count_24h:    non_neg_integer(),
    own_transfer_total_24h:    float(),
    cross_bridge_count_24h:    non_neg_integer(),
    cross_bridge_total_24h:    float(),
    unique_bridges_24h:        non_neg_integer(),
    min_gap_seconds:           non_neg_integer(),
    avg_gap_seconds:           float(),
    round_number_ratio:        float(),
    unique_counterparty_count: non_neg_integer(),
    fan_out_ratio:             float(),
    fan_in_ratio:              float(),
    wallet_age_days:           non_neg_integer() | nil
  }

  @type result :: %{
    risk_score: non_neg_integer(),
    flagged:    boolean(),
    reasons:    [String.t()],
    features:   feature_vector(),
    evidence:   map()
  }

  # ── Public API ────────────────────────────────────────────────────────────

  @spec check(String.t()) :: {:ok, result()} | {:error, term()}
  def check(wallet) do
    Logger.info("[CrossBridgeDetector] Checking wallet=#{wallet}")

    # ── DATA POINT 1: Alchemy API call (network I/O) ──────────────────────
    {t_alchemy, alchemy_result} = :timer.tc(fn -> AlchemyClient.fetch_all_chains(wallet) end)

    case alchemy_result do
      {:ok, chain_transfers} ->

        all_transfers = chain_transfers |> Map.values() |> List.flatten()

        # ── DATA POINT 2: Bridge filter (MapSet lookup × N txns) ──────────
        {t_bridge_filter, cross_bridge} = :timer.tc(fn ->
          all_transfers
          |> Enum.filter(fn t ->
            not BridgeRegistry.bharatsetu?(t.to) and
            (BridgeRegistry.known_bridge?(t.to, :eth) or
             BridgeRegistry.known_bridge?(t.to, :polygon))
          end)
        end)

        # ── DATA POINT 3: Volume aggregation (sum cross-bridge USD) ───────
        {t_volume, {cross_bridge_total, unique_bridges}} = :timer.tc(fn ->
          total   = cross_bridge |> Enum.map(& &1.value) |> Enum.sum()
          bridges = cross_bridge |> Enum.map(& &1.to) |> Enum.uniq() |> length()
          {total, bridges}
        end)

        # ── DATA POINT 4: Timestamp parse + sort (velocity prep) ──────────
        {t_timestamps, sorted_timestamps} = :timer.tc(fn ->
          all_transfers
          |> Enum.map(&parse_ts/1)
          |> Enum.filter(& &1)
          |> Enum.sort()
        end)

        # ── DATA POINT 5: Gap calculation (min/avg velocity) ──────────────
        {t_gaps, {min_gap, avg_gap}} = :timer.tc(fn ->
          gaps = sorted_timestamps
                 |> Enum.chunk_every(2, 1, :discard)
                 |> Enum.map(fn [a, b] -> DateTime.diff(b, a) end)
          min_g = if gaps == [], do: 99999, else: Enum.min(gaps)
          avg_g = if gaps == [], do: 99999.0, else: Enum.sum(gaps) / length(gaps)
          {min_g, avg_g}
        end)

        # ── DATA POINT 6: Round number ratio ──────────────────────────────
        {t_round, round_ratio} = :timer.tc(fn ->
          count = all_transfers
                  |> Enum.count(fn t ->
                    r = round(t.value)
                    rem(r, 1000) == 0 or rem(r, 1000) == 999
                  end)
          if length(all_transfers) == 0, do: 0.0, else: count / length(all_transfers)
        end)

        # ── DATA POINT 7: Fan-out ratio (receivers / total txns) ──────────
        {t_fanout, {receivers, fan_out_ratio}} = :timer.tc(fn ->
          r = all_transfers |> Enum.map(& &1.to) |> Enum.uniq()
          ratio = if length(all_transfers) == 0, do: 0.0, else: length(r) / length(all_transfers)
          {r, ratio}
        end)

        # ── DATA POINT 8: Fan-in ratio (senders / total txns) ─────────────
        {t_fanin, fan_in_ratio} = :timer.tc(fn ->
          senders = all_transfers |> Enum.map(& &1.from) |> Enum.uniq()
          if length(all_transfers) == 0, do: 0.0, else: length(senders) / length(all_transfers)
        end)

        # ── DATA POINT 9: Score evaluation (5 rule checks) ────────────────
        features = %{
          own_transfer_count_24h:    length(Map.get(chain_transfers, :bharatsetu, [])),
          own_transfer_total_24h:    0.0,
          cross_bridge_count_24h:    length(cross_bridge),
          cross_bridge_total_24h:    cross_bridge_total,
          unique_bridges_24h:        unique_bridges,
          min_gap_seconds:           min_gap,
          avg_gap_seconds:           avg_gap,
          round_number_ratio:        round_ratio,
          unique_counterparty_count: length(receivers),
          fan_out_ratio:             fan_out_ratio,
          fan_in_ratio:              fan_in_ratio,
          wallet_age_days:           nil
        }

        {t_score, {score, reasons}} = :timer.tc(fn -> score_features(features) end)

        # ── DATA POINT 10: Evidence map build ─────────────────────────────
        {t_evidence, evidence} = :timer.tc(fn -> build_evidence(chain_transfers) end)

        total = t_alchemy + t_bridge_filter + t_volume + t_timestamps +
                t_gaps + t_round + t_fanout + t_fanin + t_score + t_evidence

        ms = fn t -> Float.round(t / 1000, 3) end
        pct = fn t -> "#{Float.round(t * 100 / total, 1)}%" end

        IO.puts("""
        ╔══════════════════════════════════════════════════════════════╗
        ║         CrossBridgeDetector — Granular Timing                ║
        ╠══════╦══════════════════════════════════╦══════════╦════════╣
        ║  #   ║  Data Point                      ║  Time    ║  Share ║
        ╠══════╬══════════════════════════════════╬══════════╬════════╣
        ║  1   ║  Alchemy API fetch (network I/O) ║ #{String.pad_leading("#{ms.(t_alchemy)} ms", 8)} ║ #{String.pad_leading(pct.(t_alchemy), 6)} ║
        ║  2   ║  Bridge contract filter          ║ #{String.pad_leading("#{ms.(t_bridge_filter)} ms", 8)} ║ #{String.pad_leading(pct.(t_bridge_filter), 6)} ║
        ║  3   ║  Volume + unique bridge count    ║ #{String.pad_leading("#{ms.(t_volume)} ms", 8)} ║ #{String.pad_leading(pct.(t_volume), 6)} ║
        ║  4   ║  Timestamp parse + sort          ║ #{String.pad_leading("#{ms.(t_timestamps)} ms", 8)} ║ #{String.pad_leading(pct.(t_timestamps), 6)} ║
        ║  5   ║  Gap calc (min/avg velocity)     ║ #{String.pad_leading("#{ms.(t_gaps)} ms", 8)} ║ #{String.pad_leading(pct.(t_gaps), 6)} ║
        ║  6   ║  Round number ratio              ║ #{String.pad_leading("#{ms.(t_round)} ms", 8)} ║ #{String.pad_leading(pct.(t_round), 6)} ║
        ║  7   ║  Fan-out ratio                   ║ #{String.pad_leading("#{ms.(t_fanout)} ms", 8)} ║ #{String.pad_leading(pct.(t_fanout), 6)} ║
        ║  8   ║  Fan-in ratio                    ║ #{String.pad_leading("#{ms.(t_fanin)} ms", 8)} ║ #{String.pad_leading(pct.(t_fanin), 6)} ║
        ║  9   ║  Score evaluation (5 rules)      ║ #{String.pad_leading("#{ms.(t_score)} ms", 8)} ║ #{String.pad_leading(pct.(t_score), 6)} ║
        ║  10  ║  Evidence map build              ║ #{String.pad_leading("#{ms.(t_evidence)} ms", 8)} ║ #{String.pad_leading(pct.(t_evidence), 6)} ║
        ╠══════╩══════════════════════════════════╬══════════╬════════╣
        ║                               TOTAL     ║ #{String.pad_leading("#{ms.(total)} ms", 8)} ║  100%  ║
        ╚═════════════════════════════════════════╩══════════╩════════╝
        Txns fetched: #{length(all_transfers)} total  |  #{length(cross_bridge)} cross-bridge  |  #{unique_bridges} unique bridges
        Risk score: #{score}  |  Flagged: #{score >= 30}
        """)

        result = %{
          risk_score: score,
          flagged:    score >= 30,
          reasons:    reasons,
          features:   features,
          evidence:   evidence
        }

        Logger.info("[CrossBridgeDetector] wallet=#{wallet} score=#{score} flagged=#{result.flagged}")
        {:ok, result}

      {:error, reason} ->
        Logger.error("[CrossBridgeDetector] Failed wallet=#{wallet} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Scoring ───────────────────────────────────────────────────────────────

  def score_features(f) do
    checks = [
      {f.cross_bridge_total_24h >= @usd_threshold,
       60, "Cross-bridge total USD #{Float.round((f.cross_bridge_total_24h || 0) + 0.0, 2)} exceeds $#{@usd_threshold} in 24h"},

      {f.unique_bridges_24h >= @bridge_count_threshold,
       40, "Wallet interacted with #{f.unique_bridges_24h} different bridges in 24h"},

      {f.min_gap_seconds < @min_gap_threshold and f.cross_bridge_count_24h > 2,
       30, "Suspicious velocity: min gap #{f.min_gap_seconds}s between bridge txns"},

      {f.round_number_ratio >= @round_number_threshold and f.cross_bridge_count_24h > 0,
       20, "#{Float.round(((f.round_number_ratio || 0) + 0.0) * 100, 1)}% of transactions are round numbers"},

      {f.fan_out_ratio > 0.8 and f.cross_bridge_count_24h > 0,
       20, "High fan-out ratio #{Float.round((f.fan_out_ratio || 0) + 0.0, 2)} — possible layering"},
    ]

    checks
    |> Enum.filter(fn {condition, _, _} -> condition end)
    |> Enum.reduce({0, []}, fn {_, score, reason}, {total, reasons} ->
      {total + score, [reason | reasons]}
    end)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp build_evidence(chain_transfers) do
    chain_transfers
    |> Enum.map(fn {chain, transfers} ->
      {chain, %{
        count: length(transfers),
        total: ((transfers |> Enum.map(& &1.value) |> Enum.sum()) + 0.0) |> Float.round(4)
      }}
    end)
    |> Map.new()
  end

  defp parse_ts(%{block: ts}) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _            -> nil
    end
  end
end
