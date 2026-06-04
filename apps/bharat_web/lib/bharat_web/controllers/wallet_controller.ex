defmodule BharatWeb.WalletController do
  use BharatWeb, :controller
  alias BharatCore.Compliance.WalletHistory

  def history(conn, %{"address" => address}) do
    case WalletHistory.get(address) do
      {:ok, history} ->
        conn
        |> put_status(:ok)
        |> json(%{data: history})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: inspect(reason)})
    end
  end
end
