defmodule BharatWeb.Router do
  use BharatWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug BharatWeb.Plugs.RateLimit
    plug BharatWeb.Plugs.CorrelationId
  end

  pipeline :authenticated do
    plug BharatWeb.Plugs.VerifyJWT
    plug BharatWeb.Plugs.LoadWallet
  end

  pipeline :kyc_verified do
    plug BharatWeb.Plugs.RequireKYC
  end

  # Public
  scope "/api/v1", BharatWeb do
    pipe_through [:api]

    post "/auth/challenge", AuthController, :challenge
    post "/auth/verify",    AuthController, :verify
    get  "/prices",         PriceController, :index
    get  "/health",         HealthController, :index
    get  "/config",         ConfigController, :index
  end

  # Authenticated — read-only
  scope "/api/v1", BharatWeb do
    pipe_through [:api, :authenticated]

    get "/transfers",        TransferController, :index
    get "/transfers/:id",    TransferController, :show
    get "/transfers/:id/audit", TransferController, :audit_log

    get "/channels",                               ChannelController, :index
    get "/channels/:id",                           ChannelController, :show
    get "/channels/:id/tokens",                    ChannelController, :tokens
    get "/channels/:id/tokens/lookup",             ChannelController, :token_lookup
  end

  # KYC-gated — write operations
  scope "/api/v1", BharatWeb do
    pipe_through [:api, :authenticated, :kyc_verified]

    post   "/transfers",              TransferController, :create
    post   "/transfers/:id/lock",    TransferController, :confirm_lock
    delete "/transfers/:id",         TransferController, :cancel
    post   "/transfers/:id/retry",   TransferController, :retry
  end


end
