# BountyMarket CLI

Command-line interface for interacting with BountyMarket.

## Setup

```bash
cd cli && bun install
```

## Usage

```bash
PRIVATE_KEY=0x... bun cli/bm.ts <command> [options]
```

Output is always JSON — pipe-friendly for agents.

---

## Commands

### Direct contract (no API needed)

These call the BountyMarket contract directly.

| Command | Description |
|---------|-------------|
| `create-campaign --prize-pool <usdc> --fee <usdc> --reward <usdc>` | Lock a prize pool and open a campaign |
| `resolve --issue <id> --valid true\|false` | Accept or reject a submitted issue |
| `claim --issue <id>` | Claim winnings after resolution |
| `preview --issue <id> [--address <addr>]` | Preview claimable payout (read-only) |
| `campaign --id <id>` | Read campaign state |
| `issue --id <id>` | Read issue state |

### Via API (MPP payment gateway)

These go through the API server, which handles the MPP 402 challenge-response before relaying the on-chain call. The API must be running (`bun api/src/index.ts`).

| Command | Description |
|---------|-------------|
| `submit-issue --campaign <id> --hash <reportHash> [--api <url>]` | Pay submission fee and open an issue |
| `buy-yes --issue <id> --amount <usdc> [--api <url>]` | Buy a YES position (bet issue is valid) |
| `buy-no --issue <id> --amount <usdc> [--api <url>]` | Buy a NO position (bet issue is invalid) |

`--api` defaults to `http://localhost:3000`.

---

## Why the split?

`submit-issue`, `buy-yes`, and `buy-no` are pay-to-interact actions — the API is the MPP payment gateway that issues a 402 challenge, verifies the credential, and relays the transaction. This is what makes BountyMarket agent-native: any HTTP client that speaks MPP can submit issues or trade on markets without needing direct chain access.

`create-campaign`, `resolve`, and `claim` are admin/company actions with no payment gate, so they go straight to the contract.
