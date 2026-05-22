defmodule BharatCore.Compliance.ChainabuseClient do
  @moduledoc """
  P6 — Chainabuse scam database check. MVP stub.
  TODO: Call Chainabuse GraphQL API and return report count.
  """

  @spec check(String.t()) :: :clean | {:flagged, non_neg_integer()} | {:error, term()}
  def check(_wallet) do
    # MVP: always clean until API integration is implemented
    :clean
  end
end
