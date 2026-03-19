# BountyMarket

> Pay-to-submit bug bounties with prediction markets on issue validity. Built on [MPP](https://mpp.dev) + [Tempo](https://tempo.xyz).

Submitting a bug report is free, so platforms drown in spam. **BountyMarket fixes the incentives**: reporters pay to submit, get rewarded if valid, lose their fee if not. External agents trade on issue validity — creating a live prediction market that signals quality before the security team reads anything.

---

## Incentives

| Party | Pays | If VALID | If INVALID |
|---|---|---|---|
| **Company** | Prize pool P + 1% fee | Bug fixed | Pool unchanged |
| **Reporter** | Submission fee F (→ YES position) | 90% of R + pro-rata YES pool share | Loses F |
| **YES buyer** | Capital | Pro-rata share of (10% R + NO pool) | Loses capital |
| **NO buyer** | Capital | Loses capital | Wins entire YES pool, pro-rata |

---

## Architecture

```
BountyMarket.sol  (Tempo Mainnet — holds all USDC)
       │
       ├── Direct contract  →  Company (create, resolve) + Anyone (claim)
       │
       └── MPP API          →  Reporters + Traders (pay via HTTP 402)
```

**Direct contract**: your wallet is `msg.sender`. You own your admin rights, your position, your funds.

**MPP API**: you pay via Tempo/USDC over HTTP 402. The server relays to the contract with your wallet as beneficiary — non-custodial. You claim directly.

**Deployed:** `0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40` on Tempo Mainnet

---

## Company

Companies interact **directly with the contract** via the CLI. No API, no intermediary.

```bash
# Install: clone repo, run `forge build`, ensure bun is installed

# Create a campaign ($1000 pool, $10 submission fee, $500 reward per issue)
PRIVATE_KEY=0x... bun scripts/bm.ts create-campaign \
  --prize-pool 1000 --fee 10 --reward 500

# Check an issue (watch yesPool vs noPool for triage signal)
bun scripts/bm.ts issue --id 0

# Resolve an issue (you must be the campaign admin)
PRIVATE_KEY=0x... bun scripts/bm.ts resolve --issue 0 --valid true
# --valid false  →  NO traders win the YES pool, your prize pool is untouched
```

Output is JSON — agent-friendly.

---

## Reporter

Reporters pay the submission fee via the MPP API (HTTP 402). Your Tempo address is recorded on-chain as reporter and YES position holder.

```bash
# Check campaign details
curl https://api.bountymarket.xyz/campaigns/0

# Submit an issue (pays submission fee from your Tempo wallet)
$HOME/.tempo/bin/tempo request -t -X POST \
  --json '{"campaignId": "0", "reportHash": "ipfs://your-report-hash"}' \
  https://api.bountymarket.xyz/issues

# Check your issue's market signal
curl https://api.bountymarket.xyz/issues/0

# Preview your payout after resolution
bun scripts/bm.ts preview --issue 0 --address 0xYourAddress

# Claim (direct contract — your key, your funds)
PRIVATE_KEY=0x... bun scripts/bm.ts claim --issue 0
```

---

## Trader

Traders bet on issue validity. No security expertise required — just information edge.

**Best plays:**
- **NO on duplicates** — monitor Immunefi/Code4rena, bet NO the moment a known dupe appears here
- **YES on strong findings** — verify a PoC independently, stake YES early
- **NO on AI-generated noise** — low-effort machine submissions are often detectable by pattern

```bash
# Bet NO on suspected duplicate ($50)
$HOME/.tempo/bin/tempo request -t -X POST \
  --json '{"amount": "50000000"}' \
  https://api.bountymarket.xyz/issues/0/no

# Bet YES on strong finding ($50)
$HOME/.tempo/bin/tempo request -t -X POST \
  --json '{"amount": "50000000"}' \
  https://api.bountymarket.xyz/issues/0/yes

# Preview payout
bun scripts/bm.ts preview --issue 0 --address 0xYourAddress

# Claim
PRIVATE_KEY=0x... bun scripts/bm.ts claim --issue 0
```

**Amounts in USDC raw units (6 decimals):** `50000000` = $50 USDC.

**Autonomous agent example:**

```typescript
import { Mppx } from 'mppx/client'
const client = Mppx.create({ /* tempo wallet config */ })

// Agent detects duplicate, bets NO immediately — no human in the loop
await client.fetch('https://api.bountymarket.xyz/issues/42/no', {
  method: 'POST',
  body: JSON.stringify({ amount: '100000000' }),
})
```

---

## API Reference

| Method | Endpoint | Payment | Description |
|---|---|---|---|
| `GET` | `/campaigns/:id` | free | Campaign details |
| `GET` | `/issues/:id` | free | Issue + market state |
| `POST` | `/issues` | submission fee F | Submit issue |
| `POST` | `/issues/:id/yes` | bet amount | Buy YES |
| `POST` | `/issues/:id/no` | bet amount | Buy NO |

---

## CLI Reference (`scripts/bm.ts`)

```
bm.ts create-campaign  --prize-pool <usdc> --fee <usdc> --reward <usdc>
bm.ts resolve          --issue <id> --valid true|false
bm.ts claim            --issue <id>
bm.ts preview          --issue <id> [--address <addr>]
bm.ts campaign         --id <id>
bm.ts issue            --id <id>
```

Write commands require `PRIVATE_KEY=0x...`. All output is JSON.

---

## Local Dev

```bash
forge build
cp api/.env.example api/.env  # fill SERVER_PRIVATE_KEY, MPP_SECRET_KEY
bun run --cwd api dev
```

| Env var | Description |
|---|---|
| `SERVER_PRIVATE_KEY` | Relayer wallet key (receives MPP payments, calls contract) |
| `BOUNTY_MARKET_ADDRESS` | Deployed contract address |
| `MPP_SECRET_KEY` | HMAC secret for MPP challenge signing |

---

## Stack

| Layer | Tech |
|---|---|
| Contracts | Solidity 0.8.24, OpenZeppelin, Foundry |
| API | TypeScript, Bun, Hono, mppx, viem |
| Chain | Tempo Mainnet (chain ID 4217) |
