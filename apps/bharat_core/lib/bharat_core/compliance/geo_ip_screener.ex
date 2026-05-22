defmodule BharatCore.Compliance.GeoIpScreener do
  @moduledoc """
  P5 — Geographic/IP screening. MVP stub.
  TODO: ip-api.com + Tor exit node list check.
  """

  @spec check(String.t()) :: :allowed | {:blocked, String.t()} | {:error, term()}
  def check(_ip) do
    :allowed
  end
end
