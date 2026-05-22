defmodule BharatCore.Compliance.TrustedWallets do
  @moduledoc """
  Layer 3 — Trusted Wallet Whitelisting.
  Skips compliance checks for known internal wallets:
  relayers, treasury, bridge contracts, admin multisigs.
  Configured in config/dev.exs under :bharat_core, :trusted_wallets.
  """

  @type wallet_type :: :relayer | :treasury | :bridge_contract | :admin_multisig

  @spec trusted?(String.t()) :: boolean()
  def trusted?(wallet) do
    normalized = String.downcase(wallet)
    normalized in trusted_list()
  end

  @spec wallet_type(String.t()) :: {:ok, wallet_type()} | :not_trusted
  def wallet_type(wallet) do
    normalized = String.downcase(wallet)
    case Map.get(trusted_map(), normalized) do
      nil  -> :not_trusted
      type -> {:ok, type}
    end
  end

  defp trusted_list do
    trusted_map() |> Map.keys()
  end

  defp trusted_map do
    :bharat_core
    |> Application.get_env(:trusted_wallets, [])
    |> Enum.into(%{}, fn {wallet, type} ->
      {String.downcase(wallet), type}
    end)
  end
end
