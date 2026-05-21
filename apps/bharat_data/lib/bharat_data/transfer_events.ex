defmodule BharatData.TransferEvents do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.TransferEvent

  def list_for_transfer(transfer_id) do
    TransferEvent
    |> where([e], e.transfer_id == ^transfer_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
    |> Enum.map(&serialize/1)
  end

  defp serialize(e) do
    %{
      from_state:    e.from_state,
      to_state:      e.to_state,
      actor:         e.actor,
      chain_tx_hash: e.chain_tx_hash,
      block_number:  e.block_number,
      timestamp:     e.inserted_at
    }
  end
end
