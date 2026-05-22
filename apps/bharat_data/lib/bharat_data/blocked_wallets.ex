defmodule BharatData.BlockedWallets do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.BlockedWallet

  @doc """
  Record a blocked wallet. Called by ComplianceEngine on OFAC hit.
  Uses insert_or_ignore so re-screening the same wallet does not crash.
  """
  def record(attrs) do
    %BlockedWallet{}
    |> BlockedWallet.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :wallet_address
    )
  end

  @doc "Check if a wallet is already in the blocked list."
  def blocked?(wallet_address) do
    BlockedWallet
    |> where([b], b.wallet_address == ^String.downcase(wallet_address))
    |> Repo.exists?()
  end

  @doc "List all blocked wallets, newest first."
  def list do
    BlockedWallet
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end
end
