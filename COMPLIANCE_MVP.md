# BharatSetu — Compliance & Risk Engine
## Implementation Status + MVP Roadmap

---

## What is Built (Production-Ready)

### P1 — OFAC Screening ✅
- Every transfer (all directions) is screened against the OFAC SDN list before creation
- Primary: OpenSanctions API (`/match/default` endpoint)
- Fallback: hardcoded MapSet of known SDN addresses (used when API is unavailable)
- Fail-safe: API errors → hard block, never silently allow
- Blocked wallets persisted to `blocked_wallets` table with `wallet_address`, `reason`, `screening_api`, `direction`, `inserted_at`
- Returns HTTP 403 `{"error": "ofac_blocked"}` to frontend
- Both source and destination wallets are screened per §10.1 of production spec

### P2 — Structuring Detection ✅
- Flags wallets with more than 5 transfers in 24 hours totalling more than $10,000 USD
- Queries `transfers` table — excludes failed and rolled_back states
- Token price: 1 tCCS = 1 USD (hardcoded for POC)
- Fail-open: detector errors do not block legitimate transfers
- Returns HTTP 403 `{"error": "structuring_detected"}` to frontend
- Warning logged to server with wallet, count, and total USD

---

## What is Stubbed (MVP — Future Implementation)

All stubs are wired into the compliance module structure,
compile cleanly, and return safe defaults (clean/allow).
They are ready to be implemented without any architectural changes.

### P3 — Tainted Funds Detection
**File:** `apps/bharat_core/lib/bharat_core/compliance/tainted_funds_checker.ex`
**What it will do:** 1-hop mixer check via Alchemy.
Flag wallets that have received funds directly from known mixer contracts
(Tornado Cash, etc.). Auto-block if tainted funds > 10% of wallet history.
**Returns:** `:clean` | `{:tainted, pct}` | `{:error, reason}`
**Risk weight:** +80 (auto-block threshold)

### P4 — Counterparty Risk
**File:** `apps/bharat_core/lib/bharat_core/compliance/counterparty_risk.ex`
**What it will do:** 1-hop graph check via Etherscan txlist. Flag wallets
that have transacted directly with known bad actors (direct = +50, indirect = +20).
**Returns:** `:clean` | `{:risky, :direct | :indirect}` | `{:error, reason}`
**Risk weight:** +50 direct, +20 indirect

### P5 — Geographic/IP Screening
**File:** `apps/bharat_core/lib/bharat_core/compliance/geo_ip_screener.ex`
**What it will do:** Check request IP against sanctioned country list via
AbuseIPDB and Tor exit node list. Block transfers from OFAC-sanctioned
jurisdictions (Iran, North Korea, Cuba, Syria, Russia).
**Returns:** `:allowed` | `{:blocked, country}` | `{:error, reason}`
**Risk weight:** +40

### P6 — Chainabuse Scam Database
**File:** `apps/bharat_core/lib/bharat_core/compliance/chainabuse_client.ex`
**What it will do:** Query Chainabuse GraphQL API for community scam reports
on a wallet address. Flag if 3 or more reports found.
**Returns:** `:clean` | `{:flagged, count}` | `{:error, reason}`
**Risk weight:** +30

### P7 — Combined Risk Score Engine
**File:** `apps/bharat_core/lib/bharat_core/compliance/risk_scorer.ex`
**What it will do:** Aggregate all parameter scores into a single weighted
risk score. Persist score to `transfers.risk_score` column (migration done).
Decision thresholds:
Score >= 100  →  BLOCK  (auto-reject transfer)
Score 50–99   →  FLAG   (manual review queue)
Score < 50    →  ALLOW
Full weight table:
+100  OFAC/UN/EU SDN match      → auto-block
+80   Tainted funds > 10%       → auto-block
+60   Structuring detected
+50   Counterparty direct
+40   Sanctioned country IP
+30   Scam DB (3+ reports)
+20   Counterparty indirect
---

## Database Schema (Compliance-Related)
blocked_wallets:  wallet_address, reason, sdn_name, sdn_program,
transfer_id, direction, screening_api, metadata, inserted_at
transfers:        ... risk_score integer default 0 ...  (added via migration 20260521133410)
---

## Architecture Notes

- All compliance checks run in `BharatCore.Compliance.Engine.check_transfer/2`
- Called from `TransferController.maybe_check_compliance/3` before transfer record is created
- No transfer is ever written to DB if compliance fails
- All stubs follow the same return-type contract as live implementations
- Adding a new parameter = implement the stub + add to engine.ex `with` chain

