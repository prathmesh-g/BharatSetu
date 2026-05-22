defmodule BharatCore.Compliance.StructuringDetector do
  @moduledoc """
  P2 — Structuring detection.
  Flags wallets with >5 transfers in 24h totalling >$10,000 USD.
  Returns {:ok, :clear} or {:ok, :flagged, count, total_usd} or {:error, reason}.
  """

  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.Transfer

  @transfer_count_threshold 5
  @amount_threshold Decimal.new("10000")
  # Assume 1 tCCS = 1 USD for POC. Replace with price oracle in Week 4.
  @usd_per_token Decimal.new("1")

  @spec check(String.t()) ::
    {:ok, :clear} |
    {:ok, :flagged, non_neg_integer(), Decimal.t()} |
    {:error, term()}
  def check(wallet) when is_binary(wallet) do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

    try do
      transfers =
        Transfer
        |> where([t], t.wallet == ^wallet)
        |> where([t], t.inserted_at >= ^cutoff)
        |> where([t], t.state not in ["failed", "rolled_back"])
        |> select([t], t.amount)
        |> Repo.all()

      count = length(transfers)

      total_usd =
        transfers
        |> Enum.reduce(Decimal.new(0), fn amt, acc ->
          Decimal.add(acc, Decimal.mult(amt, @usd_per_token))
        end)

      if count > @transfer_count_threshold and
         Decimal.compare(total_usd, @amount_threshold) == :gt do
        {:ok, :flagged, count, total_usd}
      else
        {:ok, :clear}
      end
    rescue
      e -> {:error, e}
    end
  end
end
