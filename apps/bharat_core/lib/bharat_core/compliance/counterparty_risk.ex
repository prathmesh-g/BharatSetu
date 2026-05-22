defmodule BharatCore.Compliance.CounterpartyRisk do
  @moduledoc """
  P4 — Counterparty risk. MVP stub.
  TODO: 1-hop graph check via Etherscan txlist.
  """

  @spec check(String.t()) :: :clean | {:risky, :direct | :indirect} | {:error, term()}
  def check(_wallet) do
    :clean
  end
end
