#!/usr/bin/env bash
# BharatSetu — dev environment restart script
# Usage: ./dev.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$ROOT/frontend"
LOG_DIR="$ROOT/_dev_logs"
mkdir -p "$LOG_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
info() { echo -e "  ${CYAN}→${RESET}  $*"; }
fail() { echo -e "  ${RED}✗${RESET}  $*"; }
sep()  { echo -e "${DIM}────────────────────────────────────────────────────${RESET}"; }

port_open() { lsof -iTCP:"$1" -sTCP:LISTEN -t &>/dev/null; }

wait_port() {
  local port=$1 name=$2 tries=0
  while ! port_open "$port"; do
    tries=$((tries + 1))
    if [ $tries -ge 40 ]; then
      fail "$name did not come up on :$port after 40s"
      return 1
    fi
    sleep 1
  done
}

kill_port() {
  local port=$1
  local pids
  pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
  if [ -n "$pids" ]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
}

echo ""
echo -e "${BOLD}${CYAN}  BharatSetu — Dev Environment${RESET}"
sep
echo -e "  ${DIM}Includes POC v2: Anvil (CBDC) ↔ Polygon Amoy (Stablecoin)${RESET}"

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ -f "$ROOT/.env" ]; then
  set -o allexport
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +o allexport
  ok ".env loaded"
else
  warn ".env not found — copy .env.example to .env and fill in values"
  warn "Phoenix will fail to start without RELAYER_PRIVATE_KEY and RPC URLs"
fi

# ── 0. Anvil (POC v2 — local CBDC chain) ─────────────────────────────────────
echo -e "\n${BOLD}[0/5] Anvil (local CBDC ledger — POC v2)${RESET}"

if port_open 8545; then
  ok "Anvil already running on :8545"
else
  if command -v anvil &>/dev/null; then
    info "Starting Anvil on :8545..."
    anvil --port 8545 --chain-id 31337 > "$LOG_DIR/anvil.log" 2>&1 &
    echo $! > "$LOG_DIR/anvil.pid"
    sleep 2
    if port_open 8545; then
      ok "Anvil running on :8545  (logs: _dev_logs/anvil.log)"

      # Deploy POC v2 contracts if CBDC_VAULT_CONTRACT not set
      if [ -z "${CBDC_VAULT_CONTRACT:-}" ]; then
        info "CBDC_VAULT_CONTRACT not set — deploying POC v2 contracts to Anvil..."
        cd "$ROOT/contracts"
        if forge script script/DeployPOCv2.s.sol:DeployCBDC \
            --rpc-url http://localhost:8545 --broadcast \
            --private-key "${RELAYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
            > "$LOG_DIR/deploy_cbdc.log" 2>&1; then
          ok "POC v2 CBDC contracts deployed (check _dev_logs/deploy_cbdc.log for addresses)"
          warn "Set MOCK_CBDC_TOKEN and CBDC_VAULT_CONTRACT in .env, then run ./dev.sh again"
        else
          warn "POC v2 deploy failed — check _dev_logs/deploy_cbdc.log"
          warn "Hint: set RELAYER_1_ADDRESS in .env before deploying"
        fi
        cd "$ROOT"
      else
        ok "CBDC_VAULT_CONTRACT set: ${CBDC_VAULT_CONTRACT}"
      fi
    else
      warn "Anvil failed to start — POC v2 CBDC flows will not work"
      warn "Install Foundry: curl -L https://foundry.paradigm.xyz | bash"
    fi
  else
    warn "anvil not found — POC v2 CBDC flows disabled"
    warn "Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
  fi
fi

# ── 1. PostgreSQL ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/5] PostgreSQL${RESET}"
if port_open 5432; then
  ok "PostgreSQL running on :5432"
else
    info "Starting PostgreSQL..."
sudo systemctl start postgresql 2>/dev/null
sleep 2
if port_open 5432; then ok "PostgreSQL started"; else fail "PostgreSQL failed to start"; exit 1; fi
fi

# ── 2. Phoenix (kill existing, migrate, restart) ──────────────────────────────
echo -e "\n${BOLD}[2/5] Phoenix backend${RESET}"

if port_open 4000; then
  info "Killing existing Phoenix on :4000..."
  kill_port 4000
  ok "Stopped"
fi

info "Running migrations..."
cd "$ROOT"
MIX_OUT=$(MIX_ENV=dev mix ecto.migrate 2>&1 &)
MIX_PID=$!
# Wait max 20s for migrate
for i in $(seq 1 20); do
  if ! kill -0 $MIX_PID 2>/dev/null; then break; fi
  sleep 1
done
# If still running after 20s, something is wrong — kill it and continue
if kill -0 $MIX_PID 2>/dev/null; then
  kill $MIX_PID 2>/dev/null
  warn "Migrations timed out — DB may already be up to date, continuing..."
else
  ok "Migrations done"
fi

info "Starting Phoenix..."
cd "$ROOT"
MIX_ENV=dev mix phx.server > "$LOG_DIR/phoenix.log" 2>&1 &
echo $! > "$LOG_DIR/phoenix.pid"
wait_port 4000 "Phoenix" && ok "Phoenix running on :4000  (logs: _dev_logs/phoenix.log)"

# ── 3. Next.js (kill existing, restart) ──────────────────────────────────────
echo -e "\n${BOLD}[3/5] Next.js frontend${RESET}"

if port_open 3000; then
  info "Killing existing Next.js on :3000..."
  kill_port 3000
  ok "Stopped"
fi

cd "$FRONTEND_DIR"
if [ ! -d "node_modules" ]; then
  info "Installing npm deps..."
  npm install --silent > "$LOG_DIR/npm_install.log" 2>&1
  ok "npm install done"
fi

info "Starting Next.js..."
npm run dev > "$LOG_DIR/nextjs.log" 2>&1 &
echo $! > "$LOG_DIR/nextjs.pid"
wait_port 3000 "Next.js" && ok "Next.js running on :3000   (logs: _dev_logs/nextjs.log)"

# ── 4. Health checks ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}[4/5] Health checks${RESET}"
sep
sleep 1

check_url() {
  local url=$1 label=$2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "$url" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^[23] ]]; then ok "$label → $code"
  else warn "$label → $code (warming up)"
  fi
}

check_url "http://localhost:4000/api/v1/health"  "Health API  "
check_url "http://localhost:4000/api/v1/config"  "Config API  "
check_url "http://localhost:4000/api/v1/prices"  "Prices API  "
check_url "http://localhost:3000"                "Frontend    "

# ── Summary ───────────────────────────────────────────────────────────────────
LOCK=$(grep 'lock_contract' "$ROOT/config/dev.exs" 2>/dev/null | grep -oE '"0x[^"]*"' | tr -d '"' || echo "see config/dev.exs")
MINT=$(grep 'mint_contract' "$ROOT/config/dev.exs" 2>/dev/null | grep -oE '"0x[^"]*"' | tr -d '"' || echo "see config/dev.exs")

echo ""
sep
echo -e "${BOLD}${GREEN}  All set!${RESET}"
sep
echo ""
echo -e "  ${BOLD}App${RESET}"
echo -e "  ${CYAN}Frontend      ${RESET}http://localhost:3000"
echo -e "  ${CYAN}Dashboard     ${RESET}http://localhost:3000/dashboard"
echo -e "  ${CYAN}Bridge        ${RESET}http://localhost:3000/bridge"
echo -e "  ${CYAN}History       ${RESET}http://localhost:3000/history"
echo -e "  ${CYAN}Phoenix API   ${RESET}http://localhost:4000/api/v1"
echo ""
echo -e "  ${BOLD}Contracts (POC v1)${RESET}"
echo -e "  ${DIM}LockBridge (Amoy)    ${RESET}$LOCK"
echo -e "  ${DIM}MintBridge (Sepolia) ${RESET}$MINT"
echo ""
echo -e "  ${BOLD}Contracts (POC v2 — CBDC Hub)${RESET}"
echo -e "  ${DIM}Anvil chain          ${RESET}http://localhost:8545  (chain-id 31337)"
echo -e "  ${DIM}MockCBDC (INRDC)     ${RESET}${MOCK_CBDC_TOKEN:-see .env}"
echo -e "  ${DIM}CBDCVault            ${RESET}${CBDC_VAULT_CONTRACT:-see .env}"
echo -e "  ${DIM}StablecoinBridge     ${RESET}${STABLECOIN_BRIDGE_CONTRACT:-see .env}"
echo ""
echo -e "  ${BOLD}Logs${RESET}"
echo -e "  ${DIM}Phoenix   ${RESET}tail -f _dev_logs/phoenix.log"
echo -e "  ${DIM}Next.js   ${RESET}tail -f _dev_logs/nextjs.log"
echo -e "  ${DIM}Anvil     ${RESET}tail -f _dev_logs/anvil.log"
echo ""
echo -e "  ${BOLD}Quick actions${RESET}"
echo -e "  ${DIM}Restart all   ${RESET}./dev.sh"
echo -e "  ${DIM}Reset DB      ${RESET}cd $ROOT && mix ecto.reset && ./dev.sh"
echo -e "  ${DIM}Mint tCCS     ${RESET}cast send <tCCS> \"mint(address,uint256)\" <wallet> 1000000000000000000000 --rpc-url <amoy_rpc> --private-key <key>"
echo ""
sep
echo ""

open "http://localhost:3000/bridge" 2>/dev/null || true
