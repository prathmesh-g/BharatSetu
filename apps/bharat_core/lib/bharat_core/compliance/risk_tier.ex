defmodule BharatCore.Compliance.RiskTier do
  @moduledoc """
  Layer 1 — Transaction Risk Tiering.
  Assigns a compliance depth based on transfer amount.
  Small transfers → local checks only.
  Large transfers → full external screening.
  """

  @low_threshold    Decimal.new("100")
  @medium_threshold Decimal.new("1000")
  @high_threshold   Decimal.new("10000")

  @type tier :: :low | :medium | :high | :critical

  @spec assign(Decimal.t()) :: tier()
  def assign(amount) do
    cond do
      Decimal.compare(amount, @low_threshold)    == :lt -> :low
      Decimal.compare(amount, @medium_threshold) == :lt -> :medium
      Decimal.compare(amount, @high_threshold)   == :lt -> :high
      true                                               -> :critical
    end
  end

  @doc """
  Returns which compliance checks to run for a given tier.
    :low      → local OFAC fallback only
    :medium   → local OFAC + structuring
    :high     → full OFAC API + structuring + chainabuse
    :critical → all checks + manual review flag
  """
  @spec checks_for(tier()) :: [atom()]
  def checks_for(:low),     do: [:ofac_local]
  def checks_for(:medium),  do: [:ofac_local, :ofac_api, :structuring]
  def checks_for(:high),    do: [:ofac_local, :ofac_api, :structuring, :chainabuse]
  def checks_for(:critical), do: [:ofac_local, :ofac_api, :structuring, :chainabuse, :tainted_funds, :manual_review]
end
