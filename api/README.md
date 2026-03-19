# BountyMarket API

MPP payment gateway for BountyMarket. Reporters and traders pay via MPP (Tempo/USDC) — the server verifies payment, then calls the contract with the payer's wallet as the on-chain beneficiary.

**Contract:** `0x22a92a5dcd841caeb167b69c0dd8debdde6e4c40` on Tempo Mainnet
**Chain:** Tempo (chain ID 4217), USDC (6 decimals)

---

## The API is optional

The contract is the source of truth. Everything the API does can be done by calling the contract directly — the API is a convenience layer that adds MPP payment gating so agents and users can interact over standard HTTP without managing on-chain approvals themselves.

**Two actions are intentionally excluded from the API and must be done directly with the contract:**

- **Campaign creation** — `createCampaign(prizePool, submissionFee, rewardPerIssue)`. The caller's wallet becomes the campaign admin and the only address that can resolve issues. Going through a relayer would give the relayer admin rights over your funds. Use `scripts/bm.ts` or call the contract directly.
- **Claiming winnings** — `claim(issueId)`. Payouts go to `msg.sender`. Since the API records your Tempo address as the on-chain beneficiary when you submit or trade, you call claim yourself — no relayer needed, no trust assumption. Use `scripts/bm.ts` or `cast send`.

Everything else (submitting issues, buying YES/NO) can be done via the API **or** directly. The API just makes it one HTTP call instead of approve + contract call.

---

## How payments work

Every write endpoint uses MPP (Machine Payments Protocol):

1. Client sends the request — server responds `402 Payment Required` with a `WWW-Authenticate: Payment` challenge
2. Client pays the USDC amount via Tempo and retries with `Authorization: Payment <credential>`
3. Server verifies the credential, extracts the payer's Tempo address from the DID (`did:pkh:eip155:4217:0x...`), and calls the contract with that address as `beneficiary`
4. Server responds `200` with a `Payment-Receipt` header

The payer's Tempo address is recorded on-chain as the position holder — non-custodial. Users claim directly from the contract.

Using the Tempo CLI:
```bash
$HOME/.tempo/bin/tempo request -t -X POST --json '<body>' <url>
```

Using the mppx TypeScript client:
```typescript
import { Mppx } from 'mppx/client'
const client = Mppx.create({ /* tempo wallet config */ })
await client.fetch('<url>', { method: 'POST', body: JSON.stringify(<body>) })
```

---

## Endpoints

### `GET /campaigns/:id`

Returns campaign details. Free.

**Response**
```json
{
  "id": "0",
  "admin": "0x...",
  "prizePool": "1000000000",
  "submissionFee": "10000000",
  "rewardPerIssue": "500000000",
  "active": true
}
```

All amounts in USDC raw units (6 decimals). `1000000000` = $1,000 USDC.

`active: false` means the campaign has been closed by the admin — no new issues can be submitted.

---

### `GET /issues/:id`

Returns issue state including market pools. Free.

**Response**
```json
{
  "id": "0",
  "campaignId": "0",
  "reporter": "0x...",
  "yesPool": "60000000",
  "noPool": "30000000",
  "resolved": false,
  "valid": false
}
```

`yesPool` = submission fee + all YES bets. `noPool` = all NO bets.
`valid` is only meaningful when `resolved: true`.

Use `yesPool` vs `noPool` as a triage signal — high YES volume means the market believes the issue is real.

---

### `POST /issues`

Submit a bug report. MPP payment = campaign's `submissionFee`.

The fee is paid to the server wallet via Tempo. The server calls `submitIssue` on the contract, crediting the payer's Tempo address as reporter and opening a YES position in their name.

**Body**
```json
{
  "campaignId": "0",
  "reportHash": "ipfs://bafybeig..."
}
```

`reportHash` is an IPFS CID or any content-addressed pointer to the report. Stored off-chain; only the hash is referenced.

**Response `201`**
```json
{
  "issueId": "0",
  "tx": "0x..."
}
```

**MPP payment** equals `submissionFee` from the campaign (fetched on-chain before issuing the challenge).

---

### `POST /issues/:id/yes`

Buy a YES position — bet that the issue is a valid bug. MPP payment = bet amount.

On valid resolution, YES holders (including the reporter) share `YES_POOL_SHARE% of R + noPool` pro-rata by their share of `yesPool`. The reporter additionally receives `REPORTER_SHARE% of R` directly.

**Body**
```json
{
  "amount": "50000000"
}
```

Amount in USDC raw units. `50000000` = $50 USDC.

**Response `200`**
```json
{
  "issueId": "0",
  "tx": "0x..."
}
```

---

### `POST /issues/:id/no`

Buy a NO position — bet that the issue is invalid (spam, duplicate, out-of-scope). MPP payment = bet amount.

On invalid resolution, NO holders split the entire YES pool pro-rata by their share of `noPool`. The prize pool is untouched.

**Body**
```json
{
  "amount": "50000000"
}
```

**Response `200`**
```json
{
  "issueId": "0",
  "tx": "0x..."
}
```

---

## Errors

| Status | Meaning |
|---|---|
| `402` | MPP payment required — follow the challenge/credential flow |
| `400` | Bad request — missing or invalid body fields |
| `500` | On-chain call failed (campaign inactive, pool exhausted, already resolved, etc.) |

Contract revert reasons are surfaced as-is in the 500 response body.

---

## Running locally

```bash
cp .env.example .env   # fill in SERVER_PRIVATE_KEY, MPP_SECRET_KEY, BOUNTY_MARKET_ADDRESS
bun run dev            # hot reload on :3000
bun run start          # production
```

**Environment variables**

| Variable | Description |
|---|---|
| `SERVER_PRIVATE_KEY` | Tempo wallet key for the relayer. Receives MPP payments and calls the contract. Must be funded with USDC and pathUSD (for gas). |
| `BOUNTY_MARKET_ADDRESS` | Deployed BountyMarket contract address. |
| `MPP_SECRET_KEY` | HMAC secret used to bind and verify MPP challenges. Set to a random string. |
| `PORT` | Port to listen on (default: `3000`). |
