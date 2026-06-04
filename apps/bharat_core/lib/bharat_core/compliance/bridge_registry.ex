defmodule BharatCore.Compliance.BridgeRegistry do
  @moduledoc """
  Known bridge contract addresses across chains.
  Used for cross-bridge structuring detection.
  """

  @eth_bridges MapSet.new([
    # Hop Protocol
    "0x3666f603cc164936c1b87e207f36beba4ac5f18a",
    "0x76b22b8c1079a44f1211d867d68b1aca6b8f98b5",
    # Across Protocol
    "0x5c7bcd6e7de5423a257d81b442095a1a6ced35c5",
    "0xe35e9842fceaca96570b734083f4a58e8f7c5f2a",
    # Stargate Finance
    "0x8731d54e9d02c286767d56ac03e8037c07e01e98",
    "0x296f55f8fb28e498b858d0bcda06d955b2cb3f97",
    # Synapse Protocol
    "0x2796317b0ff8538f253012862c06787adfb8ceb6",
    # Celer cBridge
    "0x5427fefa711eff984124bfbb1ab6fbf5e3da1820",
    # Orbiter Finance
    "0x80c67432656d59144ceff962e8faf8926599bcf8",
    # BharatSetu own
    "0xfeca77ae1422d4d389f03fc467c2e0a1fd942f33",
    "0x878c08e769eb98762835dfd7b03a1e5ef435cc5a",
  ])

  @polygon_bridges MapSet.new([
    # Polygon native bridge
    "0xa0c68c638235ee32657e8f720a23cec1bfc77c77",
    # Hop Protocol on Polygon
    "0x553bc791d746767166fa3888432038193ceed5e2",
    # Stargate on Polygon
    "0x45a01e4e04f14f7a4a6702c74187c5f6222033cd",
    # Celer on Polygon
    "0x88dcdc47d2f83a99cf0000fdf667a468bb958a78",
    # BharatSetu own
    "0x6cbc54aec71af29b34238a1db9a50f731c379933",
  ])

  @bharatsetu_contracts MapSet.new([
    "0xfeca77ae1422d4d389f03fc467c2e0a1fd942f33",
    "0x878c08e769eb98762835dfd7b03a1e5ef435cc5a",
    "0x6cbc54aec71af29b34238a1db9a50f731c379933",
  ])

  @spec bharatsetu?(String.t()) :: boolean()
  def bharatsetu?(addr), do: MapSet.member?(@bharatsetu_contracts, String.downcase(addr))

  @spec known_bridge?(String.t(), :eth | :polygon) :: boolean()
  def known_bridge?(addr, chain) do
    normalized = String.downcase(addr)
    case chain do
      :eth     -> MapSet.member?(@eth_bridges, normalized)
      :polygon -> MapSet.member?(@polygon_bridges, normalized)
    end
  end

  @spec all_bridges() :: MapSet.t()
  def all_bridges, do: MapSet.union(@eth_bridges, @polygon_bridges)
end
