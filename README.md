# BountyMarket

> Pay-to-submit bug bounties with prediction markets on issue validity. Built on [MPP](https://mpp.dev) + [Tempo](https://tempo.xyz).

Bug bounty platforms are broken. Submitting an issue is free, so platforms get flooded with spam — low-effort AI-generated reports, duplicates, noise. Security teams waste hours triaging junk instead of fixing real bugs.

**BountyMarket fixes the incentives.**

Reporters pay a fee to submit an issue. If it's valid, they get rewarded. If not, they lose the fee. External agents can trade on whether any given issue is real — creating a live prediction market that signals issue quality *before* the security team even reads it.

The result: spam becomes economically irrational, real bugs get amplified, and AI agents can participate on both sides of the market.

---

## How It Works

### The Roles

| Role | What you do |
|---|---|
| **Company** | Open a campaign, lock a prize pool, resolve issues |
| **Reporter** | Pay to submit an issue, earn the bounty if valid |
| **YES trader** | Bet an issue is valid, earn if confirmed |
| **NO trader** | Bet an issue is invalid (e.g. it's a duplicate), earn if rejected |

### Incentive Matrix

| Party | Pays | If VALID | If INVALID |
|---|---|---|---|
| **Company** | Prize pool P + 1% protocol fee | Bug fixed, secure | Pool unchanged |
| **Reporter** | Submission fee F → becomes YES position | 90% of reward R + pro-rata share of (10% R + NO pool) | Loses F |
| **YES buyers** | Capital | Pro-rata share of (10% R + NO pool) | Lose capital |
| **NO buyers** | Capital | Lose capital | Win entire YES pool (F + all YES buys), pro-rata |

### Why This Works

- **Spam filter**: submitting costs money. You only submit if you believe in your finding.
- **Signal amplification**: YES buyers do independent due diligence and stake on it — a heavily-bought YES position tells the security team to prioritize this issue.
- **Duplicate detection**: agents that monitor Immunefi, Code4rena, and public disclosures can instantly bet NO on known duplicates and profit. This is a natural market role with real information edge.
- **No company conflict**: companies earn nothing from rejections, so there's no incentive to wrongly deny valid issues.

### Payment Flow

All payments go through [MPP](https://mpp.dev) — the open protocol for machine-to-machine payments. Every write endpoint returns an HTTP 402 challenge. Pay in USDC via Tempo. No accounts, no API keys, no signups.

```
Agent / Human
  │
  │  POST /issues
  │  ← 402 Payment Required (pay F USDC via Tempo)
  │  → retry with payment credential
  │
BountyMarket API  (MPP server)
  │  verifies payment
  │  submits tx on-chain
  │
BountyMarket.sol  (Tempo Mainnet)
```

---

## Deployed Contracts

| Network | Address |
|---|---|
| Tempo Mainnet | `0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40` |

---

## API Reference

All write endpoints require MPP payment. Read endpoints are free.

| Method | Endpoint | MPP Payment | Description |
|---|---|---|---|
| `GET` | `/campaigns/:id` | free | Get campaign details |
| `POST` | `/campaigns` | prize pool amount | Create a campaign |
| `GET` | `/issues/:id` | free | Get issue + market state |
| `POST` | `/issues` | submission fee F | Submit an issue |
| `POST` | `/issues/:id/yes` | bet amount | Buy YES position |
| `POST` | `/issues/:id/no` | bet amount | Buy NO position |
| `POST` | `/issues/:id/resolve` | admin key | Resolve an issue (company only) |

---

## Role Guides

### Company

You open a campaign, lock a prize pool, and resolve issues. You pay once upfront. The market does your triage for free.

**1. Set up the Tempo CLI**

```bash
curl -fsSL https://tempo.xyz/install | bash
tempo wallet login
```

**2. Create a campaign**

```bash
tempo request -t -X POST \
  --json '{
    "prizePool":      "1000000000",
    "submissionFee":  "10000000",
    "rewardPerIssue": "500000000"
  }' \
  http://localhost:3000/campaigns
```

Amounts are in USDC raw units (6 decimals):

| Field | Example value | Meaning |
|---|---|---|
| `prizePool` | `1000000000` | $1,000 USDC total pool |
| `submissionFee` | `10000000` | $10 USDC per submission |
| `rewardPerIssue` | `500000000` | $500 USDC per valid issue |

You pay `prizePool + 1%` at creation. The 1% is the protocol fee.

**3. Monitor issues**

```bash
curl http://localhost:3000/issues/0
```

Check `yesPool` vs `noPool`. High YES volume = market thinks it's real. High NO volume = likely spam or duplicate. Use this to prioritize your review queue.

**4. Resolve an issue**

```bash
curl -X POST http://localhost:3000/issues/0/resolve \
  -H "Content-Type: application/json" \
  -d '{"valid": true, "adminKey": "your-admin-key"}'
```

- `valid: true` → reporter + YES traders paid, `rewardPerIssue` deducted from pool
- `valid: false` → NO traders win the YES pool, your prize pool is untouched

---

### Reporter

You pay the submission fee to open an issue. Your fee becomes a YES position. If your issue is confirmed valid, you receive 90% of the reward from the prize pool plus your share of whatever NO traders staked against you.

**Submitting a valid, well-researched issue costs you nothing net** — your fee comes back as part of your payout.

**1. Check the campaign**

```bash
curl http://localhost:3000/campaigns/0
```

Note `submissionFee` and `rewardPerIssue`. Make sure the reward justifies your effort.

**2. Submit your issue**

```bash
tempo request -t -X POST \
  --json '{"campaignId": "0", "reportHash": "ipfs://your-report-hash"}' \
  http://localhost:3000/issues
```

The MPP payment equals the submission fee F, deducted automatically from your Tempo wallet.

**3. Watch the market**

After submitting, poll your issue and watch `yesPool` and `noPool`. If NO traders pile in quickly, the market may be flagging your issue as a duplicate — worth double-checking before the company reviews it.

**4. Claim your winnings**

After the company resolves the issue:

```bash
cast send 0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40 \
  "claim(uint256)" 0 \
  --rpc-url https://rpc.tempo.xyz \
  --private-key $YOUR_KEY
```

Or preview your payout first:

```bash
cast call 0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40 \
  "previewClaim(uint256,address)(uint256)" 0 $YOUR_ADDRESS \
  --rpc-url https://rpc.tempo.xyz
```

---

### Trader

You trade on issue validity without submitting issues yourself. You profit purely from being right. No security expertise required — just information edge.

**Best opportunities:**

- **NO on duplicates** — monitor Immunefi, Code4rena, and public disclosures. The moment a duplicate appears on BountyMarket, be first to bet NO. Early NO buyers get the best price and highest share of the pot.
- **YES on strong findings** — if you can verify a PoC independently, stake YES early and amplify a real bug.
- **NO on AI-generated noise** — low-effort machine-generated submissions are often detectable by pattern. The NO market rewards fast, accurate spam detection.

**1. Buy a NO position (example: betting against a suspected duplicate)**

```bash
tempo request -t -X POST \
  --json '{"amount": "50000000"}' \
  http://localhost:3000/issues/0/no
```

`50000000` = $50 USDC

**2. Buy a YES position**

```bash
tempo request -t -X POST \
  --json '{"amount": "50000000"}' \
  http://localhost:3000/issues/0/yes
```

**3. Preview your payout**

```bash
cast call 0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40 \
  "previewClaim(uint256,address)(uint256)" 0 $YOUR_ADDRESS \
  --rpc-url https://rpc.tempo.xyz
```

**4. Claim after resolution**

```bash
cast send 0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40 \
  "claim(uint256)" 0 \
  --rpc-url https://rpc.tempo.xyz \
  --private-key $YOUR_KEY
```

**Building an autonomous trading agent:**

The API is fully MPP-native. Any agent with a Tempo wallet can trade without human involvement:

```typescript
import { Mppx } from 'mppx/client'

const client = Mppx.create({ /* tempo wallet config */ })

// Agent detects a duplicate, bets NO immediately
const res = await client.fetch('http://localhost:3000/issues/42/no', {
  method: 'POST',
  body: JSON.stringify({ amount: '100000000' }),
})
```

No API keys. No accounts. No signups. The agent discovers the endpoint, pays via HTTP 402 challenge-response, and trades — fully autonomously.

---

## Local Development

```bash
git clone <repo>
cd bountymarket

# Build contracts
forge build

# Deploy to Tempo
cd api
cp .env.example .env   # fill in your keys
bun run deploy.ts

# Start the API
bun run dev
```

**Environment variables:**

| Variable | Description |
|---|---|
| `SERVER_PRIVATE_KEY` | Tempo wallet spending key (from `tempo wallet login`) |
| `BOUNTY_MARKET_ADDRESS` | Deployed contract address |
| `MPP_SECRET_KEY` | Random secret for MPP challenge signing |
| `ADMIN_KEY` | Secret for the resolve endpoint |

---

## Stack

| Layer | Tech |
|---|---|
| Contracts | Solidity 0.8.24, OpenZeppelin, Foundry |
| API | TypeScript, Bun, Hono, mppx, viem |
| Payments | MPP, Tempo blockchain, USDC |
| Chain | Tempo Mainnet (chain ID 4217) |
