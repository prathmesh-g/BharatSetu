defmodule BharatCore.Compliance.TaintedFundsChecker do
  @moduledoc """
  P3 — Tainted funds detection. MVP stub.
  TODO: 1-hop mixer check via Polygonscan/Etherscan txlist API.
  """

  @spec check(String.t()) :: :clean | {:tainted, float()} | {:error, term()}
  def check(_wallet) do
    :clean
  end
end
