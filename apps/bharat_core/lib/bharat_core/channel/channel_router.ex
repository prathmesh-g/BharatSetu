defmodule BharatCore.Channel.ChannelRouter do
  @moduledoc """
  Routes transfer requests to the correct channel based on direction.
  Holds static channel configurations in application env, seeding DB on startup.
  """

  alias BharatCore.Channel.IdentifierStrategy
  alias BharatData.{Channels, TokenRegistry}

  # ── Channel configs ──────────────────────────────────────────────────────

  @channels %{
    "eth-sol-v1" => %{
      id:              "eth-sol-v1",
      name:            "Ethereum ↔ Solana",
      zone_a:          "ethereum",
      zone_b:          "solana",
      zone_a_chain_id: 80_002,         # Amoy (testnet)
      zone_b_cluster:  "devnet",
      config: %{
        confirmation_depth_a: 3,
        confirmation_depth_b: 32,
        timeout_sec:          3600,
        identifier_strategy:  IdentifierStrategy.Default
      }
    }
  }

  # ── Public API ────────────────────────────────────────────────────────────

  def get_channel(channel_id), do: Map.get(@channels, channel_id)

  def channel_for_direction("eth_to_sol"),     do: {:ok, get_channel("eth-sol-v1")}
  def channel_for_direction("sol_to_eth"),     do: {:ok, get_channel("eth-sol-v1")}
  def channel_for_direction("eth_nft_to_sol"), do: {:ok, get_channel("eth-sol-v1")}
  def channel_for_direction("sol_nft_to_eth"), do: {:ok, get_channel("eth-sol-v1")}
  def channel_for_direction(_),                do: {:error, :no_channel}

  def generate_cross_chain_id(channel_id, zone, sender, context \\ %{}) do
    channel = get_channel(channel_id)
    strategy = get_in(channel, [:config, :identifier_strategy]) || IdentifierStrategy.Default
    strategy.generate(channel_id, zone, sender, context)
  end

  def timeout_at(channel_id) do
    channel = get_channel(channel_id)
    secs = get_in(channel, [:config, :timeout_sec]) || 3600
    DateTime.add(DateTime.utc_now(), secs, :second)
  end

  # Check token version: is this address a wrapped token on this channel?
  def token_version(channel_id, chain, address) do
    if TokenRegistry.is_wrapped?(channel_id, chain, address),
      do: "wrapped",
      else: "original"
  end

  # Seed DB with static channel configs on startup.
  def seed_channels do
    Enum.each(@channels, fn {_id, cfg} ->
      Channels.upsert(%{
        id:              cfg.id,
        name:            cfg.name,
        zone_a:          cfg.zone_a,
        zone_b:          cfg.zone_b,
        zone_a_chain_id: cfg.zone_a_chain_id,
        zone_b_cluster:  cfg.zone_b_cluster,
        config:          Map.drop(cfg.config, [:identifier_strategy]) |> Map.new(fn {k, v} -> {to_string(k), v} end)
      })
    end)
  end
end
