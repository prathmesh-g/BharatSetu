defmodule BharatCore.Compliance.WalletCache do
  @moduledoc """
  Layer 2 — Wallet Reputation Cache.
  Stores OFAC screening results in ETS to avoid repeated API calls.
  TTL: 24 hours for :clear, 7 days for :blocked (blocked wallets don't un-block quickly).
  """

  use GenServer

  @table       :wallet_reputation_cache
  @clear_ttl   86_400      # 24 hours in seconds
  @blocked_ttl 604_800     # 7 days in seconds

  ## Client API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec get(String.t()) :: {:ok, :clear} | {:ok, :blocked, String.t()} | :miss
  def get(wallet) do
    case :ets.lookup(@table, String.downcase(wallet)) do
      [{_wallet, result, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, result}
        else
          :ets.delete(@table, String.downcase(wallet))
          :miss
        end
      [] -> :miss
    end
  end

  @spec put(String.t(), :clear | {:blocked, String.t()}) :: :ok
  def put(wallet, result) do
    ttl = if result == :clear, do: @clear_ttl, else: @blocked_ttl
    expires_at = System.system_time(:second) + ttl
    :ets.insert(@table, {String.downcase(wallet), result, expires_at})
    :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(wallet) do
    :ets.delete(@table, String.downcase(wallet))
    :ok
  end

  ## Server callbacks

  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.hours(1))
  end
end
