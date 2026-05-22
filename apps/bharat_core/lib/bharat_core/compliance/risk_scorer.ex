defmodule BharatCore.Compliance.RiskScorer do
  @moduledoc """
  P7 — Combined risk score engine. MVP stub.
  TODO: Weighted sum of all parameters. Persist score to transfers.risk_score.

  Score weights:
    +100  OFAC/SDN match        → auto-block (score >= 100)
    +80   Tainted funds >10%    → auto-block
    +60   Structuring detected
    +50   Counterparty direct
    +40   Sanctioned country IP
    +30   Scam DB (3+ reports)
    +20   Counterparty indirect

  Score >= 100 → :block
  Score 50-99  → :flag
  Score < 50   → :allow
  """

  @spec score(String.t()) :: {non_neg_integer(), :block | :flag | :allow, [String.t()]}
  def score(_wallet) do
    # MVP: returns zero score, allow all
    {0, :allow, []}
  end
end
