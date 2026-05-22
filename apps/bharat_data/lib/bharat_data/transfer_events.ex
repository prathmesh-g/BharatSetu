defmodule BharatData.TransferEvents do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.TransferEvent

  @doc """
  Append an immutable audit event. Returns {:ok, event} or {:error, changeset}.
  Required keys: :transfer_id, :to_state, :actor
  Optional keys: :from_state, :chain_tx_hash, :block_number, :metadata
  """
  def append(attrs) do
    %TransferEvent{}
    |> TransferEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Same as append/1 but raises on failure.
  Use inside the FSM — a missing audit entry is worse than a process crash.
  """
  def append!(attrs) do
    %TransferEvent{}
    |> TransferEvent.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Return all audit events for a transfer, oldest first.
  """
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
