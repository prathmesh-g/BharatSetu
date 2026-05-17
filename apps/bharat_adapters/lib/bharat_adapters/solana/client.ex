defmodule BharatAdapters.Solana.Client do
  @moduledoc """
  Solana JSON-RPC client for BharatSetu bridge.
  Polls getSignaturesForAddress, fetches transactions, parses Anchor events from logs.
  """

  require Logger

  @commitment "finalized"

  # ── Slot / block ─────────────────────────────────────────────────────────────

  def get_slot do
    case rpc("getSlot", [%{commitment: @commitment}]) do
      {:ok, slot} when is_integer(slot) -> {:ok, slot}
      {:ok, val} -> {:error, {:unexpected_slot, val}}
      err -> err
    end
  end

  # ── Signature polling ─────────────────────────────────────────────────────────

  # Returns list of %{signature, slot, err, blockTime} maps, newest-first.
  # Pass until: last_known_sig to stop at known watermark.
  def get_signatures_for_address(program_id, opts \\ []) do
    params_map =
      %{commitment: @commitment}
      |> maybe_put(:limit, Keyword.get(opts, :limit, 100))
      |> maybe_put(:until, Keyword.get(opts, :until))
      |> maybe_put(:before, Keyword.get(opts, :before))

    case rpc("getSignaturesForAddress", [program_id, params_map]) do
      {:ok, sigs} when is_list(sigs) ->
        parsed =
          Enum.map(sigs, fn s ->
            %{
              signature:  s["signature"],
              slot:       s["slot"],
              err:        s["err"],
              block_time: s["blockTime"]
            }
          end)
        {:ok, parsed}

      {:ok, val} ->
        {:error, {:unexpected_sigs, val}}

      err ->
        err
    end
  end

  # ── Transaction fetch + event parsing ────────────────────────────────────────

  def get_transaction(signature) do
    params = [
      signature,
      %{
        encoding: "jsonParsed",
        commitment: @commitment,
        maxSupportedTransactionVersion: 0
      }
    ]

    case rpc("getTransaction", params) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, tx}  -> {:ok, tx}
      err        -> err
    end
  end

  # Extract log messages from a fetched transaction.
  def get_logs(tx) when is_map(tx) do
    get_in(tx, ["meta", "logMessages"]) || []
  end

  # Parse Anchor program logs for a specific event discriminator (base64 prefix).
  # Anchor emits: "Program data: <base64(discriminator ++ borsh_data)>"
  # discriminator = first 8 bytes of sha256("event:<EventName>")
  def parse_anchor_event(logs, event_discriminator_b64) when is_list(logs) do
    Enum.find_value(logs, fn log ->
      case log do
        "Program data: " <> b64 ->
          case Base.decode64(b64) do
            {:ok, <<disc::binary-8, rest::binary>>} ->
              expected = Base.decode64!(event_discriminator_b64)
              if disc == expected, do: rest, else: nil
            _ ->
              nil
          end

        _ ->
          nil
      end
    end)
  end

  # ── High-level event decoders ─────────────────────────────────────────────────

  # Decode TokenLocked event from lock_vault program logs.
  # Borsh layout: sender[32] + dest_eth_wallet[20] + amount[u64-le] + cross_chain_id[32] + timeout_at[i64-le]
  def decode_token_locked(raw_borsh) when is_binary(raw_borsh) do
    case raw_borsh do
      <<sender::binary-32, dest_eth::binary-20, amount::little-unsigned-64,
        ccid::binary-32, timeout::little-signed-64, _rest::binary>> ->
        {:ok, %{
          event:          :token_locked,
          sender:         Base.encode16(sender, case: :lower),
          dest_eth_wallet: "0x" <> Base.encode16(dest_eth, case: :lower),
          amount:         amount,
          cross_chain_id: "0x" <> Base.encode16(ccid, case: :lower),
          timeout_at:     timeout
        }}

      _ ->
        {:error, :decode_failed}
    end
  end

  # Decode NftLocked event from nft_vault program logs.
  # Borsh layout: sender[32] + mint[32] + dest_eth_wallet[20] + cross_chain_id[32] +
  #               nonce_hash[32] + metadata_uri[u32-le len + bytes] + metadata_hash[32] + timeout_at[i64]
  def decode_nft_locked(raw_borsh) when is_binary(raw_borsh) do
    case raw_borsh do
      <<sender::binary-32, mint::binary-32, dest_eth::binary-20, ccid::binary-32,
        nonce_hash::binary-32, uri_len::little-unsigned-32, rest::binary>> ->
        case rest do
          <<uri::binary-size(uri_len), meta_hash::binary-32, timeout::little-signed-64, _::binary>> ->
            {:ok, %{
              event:          :nft_locked,
              sender:         Base.encode16(sender, case: :lower),
              mint:           Base.encode16(mint, case: :lower),
              dest_eth_wallet: "0x" <> Base.encode16(dest_eth, case: :lower),
              cross_chain_id: "0x" <> Base.encode16(ccid, case: :lower),
              nonce_hash:     "0x" <> Base.encode16(nonce_hash, case: :lower),
              metadata_uri:   uri,
              metadata_hash:  "0x" <> Base.encode16(meta_hash, case: :lower),
              timeout_at:     timeout
            }}

          _ ->
            {:error, :decode_failed}
        end

      _ ->
        {:error, :decode_failed}
    end
  end

  # ── ETH→SOL minting ──────────────────────────────────────────────────────────

  @doc """
  Mint wrapped SPL tokens on Solana for an ETH→SOL transfer.
  Delegates to solana/scripts/mint_wrapped.js via System.cmd.

  cross_chain_id_hex: "0x..." (32-byte hex)
  amount_spl:         integer SPL lamports (wei / 10^9, 9-decimal)
  eth_lock_nonce_hex: "0x..." nonceHash from ETH lock event
  dest_wallet:        Base58 Solana pubkey of recipient
  """
  def mint_wrapped(cross_chain_id_hex, amount_spl, eth_lock_nonce_hex, dest_wallet) do
    script = script_path("mint_wrapped.js")
    env    = build_env()
    args   = [cross_chain_id_hex, Integer.to_string(amount_spl), eth_lock_nonce_hex, dest_wallet]

    Logger.info("[SolanaClient] mint_wrapped ccid=#{cross_chain_id_hex} amount=#{amount_spl} dest=#{dest_wallet}")

    case System.cmd("node", [script | args], env: env, stderr_to_stdout: false) do
      {output, 0} ->
        case extract_mint_sig(output) do
          {:ok, sig} ->
            Logger.info("[SolanaClient] mint_wrapped success sig=#{sig}")
            {:ok, sig}
          :error ->
            Logger.error("[SolanaClient] mint_wrapped: no MINT_SIG in output: #{output}")
            {:error, {:no_sig_in_output, output}}
        end

      {output, code} ->
        Logger.error("[SolanaClient] mint_wrapped script exit=#{code}: #{output}")
        {:error, {:script_failed, code, output}}
    end
  end

  defp extract_mint_sig(output) do
    case Regex.run(~r/^MINT_SIG=(\S+)/m, output) do
      [_, sig] -> {:ok, sig}
      nil      -> :error
    end
  end

  defp script_path(name) do
    app_dir = Application.app_dir(:bharat_adapters)
    # _build/dev/lib/bharat_adapters → 4 levels up → repo root
    root = app_dir |> Path.join("../../../..") |> Path.expand()
    Path.join([root, "solana", "scripts", name])
  end

  defp build_env do
    rpc_url      = Application.get_env(:bharat_adapters, :solana_rpc_url) || "https://api.devnet.solana.com"
    keypair      = Application.get_env(:bharat_adapters, :solana_relayer_keypair) || "~/.config/solana/id.json"
    wrapped_mint = Application.get_env(:bharat_adapters, :solana_wrapped_mint) || ""
    [
      {"SOLANA_RPC_URL",        rpc_url},
      {"SOLANA_RELAYER_KEYPAIR", String.replace(keypair, "~", System.get_env("HOME") || "")},
      {"SOLANA_WRAPPED_MINT",   wrapped_mint},
      {"PATH", "/home/prathuu/.nvm/versions/node/v20.20.2/bin:" <> (System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin")},
    ]
  end

  # ── Rollback: claim_timeout on lock_vault ────────────────────────────────────

  def claim_timeout(cross_chain_id_hex, _solana_sig \\ nil) do
    Logger.info("[SolanaClient] claim_timeout cross_chain_id=#{cross_chain_id_hex} (POC: logged only)")
    {:ok, :logged}
  end

  # ── JSON-RPC ──────────────────────────────────────────────────────────────────

  defp rpc(method, params) do
    url  = solana_rpc_url()
    body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})

    case Req.post(url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{body: %{"error" => err}}} ->
        {:error, {:rpc_error, err}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp solana_rpc_url do
    Application.get_env(:bharat_adapters, :solana_rpc_url) ||
      "https://api.devnet.solana.com"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val),  do: Map.put(map, key, val)
end
