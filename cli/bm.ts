#!/usr/bin/env bun
/**
 * BountyMarket CLI
 *
 * Usage:
 *   bun cli/bm.ts <command> [options]
 *
 * Direct contract commands (require PRIVATE_KEY):
 *   create-campaign  --prize-pool <usdc> --fee <usdc> --reward <usdc>
 *   resolve          --issue <id> --valid true|false
 *   claim            --issue <id>
 *   preview          --issue <id> [--address <addr>]
 *
 * Read commands (no key required):
 *   campaign         --id <id>
 *   issue            --id <id>
 *
 * MPP commands (require PRIVATE_KEY, API must be running):
 *   submit-issue     --campaign <id> --hash <reportHash> [--api <url>]
 *   buy-yes          --issue <id> --amount <usdc> [--api <url>]
 *   buy-no           --issue <id> --amount <usdc> [--api <url>]
 *
 * Output is JSON — pipe-friendly for agents.
 */

import { createWalletClient, createPublicClient, http, parseUnits, formatUnits, defineChain } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Mppx, tempo } from 'mppx/client'
import { readFileSync } from 'fs'
import path from 'path'

// ── Chain + contract config ──────────────────────────────────────────────────

const CONTRACT = '0x0Abb6362735a87a9b940Bcd2b7a35ead9927E92d' as `0x${string}`
const USDC     = '0x20C000000000000000000000b9537d11c60E8b50' as `0x${string}`
const PATH_USD = '0x20c0000000000000000000000000000000000000' as `0x${string}`

const tempoChain = defineChain({
  id: 4217,
  name: 'Tempo',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.tempo.xyz'] } },
})

const abi = JSON.parse(
  readFileSync(path.resolve(import.meta.dir, '../out/BountyMarket.sol/BountyMarket.json'), 'utf8')
).abi

const erc20Abi = [{
  name: 'approve', type: 'function',
  inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
  outputs: [{ type: 'bool' }], stateMutability: 'nonpayable',
}] as const

// ── Clients ──────────────────────────────────────────────────────────────────

const publicClient = createPublicClient({ chain: tempoChain, transport: http() })

function getWalletClient() {
  if (!process.env.PRIVATE_KEY) { err('PRIVATE_KEY env var required for write commands'); process.exit(1) }
  const account = privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`)
  return { client: createWalletClient({ account, chain: tempoChain, transport: http() }), account }
}

function getMppxClient() {
  if (!process.env.PRIVATE_KEY) { err('PRIVATE_KEY env var required'); process.exit(1) }
  const account = privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`)
  return Mppx.create({ methods: [tempo.charge({ account })] })
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function err(msg: string) { console.error(`error: ${msg}`) }
function out(data: unknown) { console.log(JSON.stringify(data, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2)) }

const args = process.argv.slice(2)
const cmd = args[0]
const flag = (f: string, required = true): string => {
  const i = args.indexOf(f)
  if (i === -1 || !args[i + 1]) {
    if (required) { err(`missing ${f}`); process.exit(1) }
    return ''
  }
  return args[i + 1]
}

// ── Commands ─────────────────────────────────────────────────────────────────

if (cmd === 'create-campaign') {
  const prizePool      = parseUnits(flag('--prize-pool'), 6)
  const submissionFee  = parseUnits(flag('--fee'), 6)
  const rewardPerIssue = parseUnits(flag('--reward'), 6)
  const { client, account } = getWalletClient()
  const total = prizePool + prizePool / 100n

  console.error(`creating campaign from ${account.address}`)
  console.error(`approving $${formatUnits(total, 6)} USDC...`)

  const approveHash = await client.writeContract({
    address: USDC, abi: erc20Abi, functionName: 'approve',
    args: [CONTRACT, total], feeToken: PATH_USD,
  } as any)
  await publicClient.waitForTransactionReceipt({ hash: approveHash })

  console.error('creating campaign...')
  const hash = await client.writeContract({
    address: CONTRACT, abi, functionName: 'createCampaign',
    args: [prizePool, submissionFee, rewardPerIssue], feeToken: PATH_USD,
  } as any)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  const log = receipt.logs.find(l => l.address.toLowerCase() === CONTRACT.toLowerCase())!
  const campaignId = BigInt(log.topics[1] ?? '0x0')
  out({ campaignId, tx: hash, admin: account.address, prizePool: prizePool.toString(), submissionFee: submissionFee.toString(), rewardPerIssue: rewardPerIssue.toString() })

} else if (cmd === 'resolve') {
  const issueId = BigInt(flag('--issue'))
  const valid   = flag('--valid') === 'true'
  const { client, account } = getWalletClient()

  console.error(`resolving issue ${issueId} as ${valid ? 'VALID' : 'INVALID'} from ${account.address}`)
  const hash = await client.writeContract({
    address: CONTRACT, abi, functionName: 'resolve',
    args: [issueId, valid], feeToken: PATH_USD,
  } as any)
  await publicClient.waitForTransactionReceipt({ hash })
  out({ issueId, valid, tx: hash })

} else if (cmd === 'claim') {
  const issueId = BigInt(flag('--issue'))
  const { client, account } = getWalletClient()

  console.error(`claiming issue ${issueId} for ${account.address}`)
  const hash = await client.writeContract({
    address: CONTRACT, abi, functionName: 'claim',
    args: [issueId], feeToken: PATH_USD,
  } as any)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  out({ issueId, tx: hash, status: receipt.status })

} else if (cmd === 'preview') {
  const issueId = BigInt(flag('--issue'))
  const address = (flag('--address', false) || (process.env.PRIVATE_KEY ? privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`).address : '')) as `0x${string}`
  if (!address) { err('provide --address or set PRIVATE_KEY'); process.exit(1) }

  const payout = await publicClient.readContract({
    address: CONTRACT, abi, functionName: 'previewClaim', args: [issueId, address],
  }) as bigint
  out({ issueId, address, payout: payout.toString(), payoutUsdc: formatUnits(payout, 6) })

} else if (cmd === 'campaign') {
  const id = BigInt(flag('--id'))
  const c = await publicClient.readContract({ address: CONTRACT, abi, functionName: 'campaigns', args: [id] }) as any[]
  out({ id, admin: c[0], prizePool: c[1].toString(), submissionFee: c[2].toString(), rewardPerIssue: c[3].toString(), active: c[4] })

} else if (cmd === 'issue') {
  const id = BigInt(flag('--id'))
  const i = await publicClient.readContract({ address: CONTRACT, abi, functionName: 'issues', args: [id] }) as any[]
  out({ id, campaignId: i[0].toString(), reporter: i[1], yesPool: i[2].toString(), noPool: i[3].toString(), resolved: i[4], valid: i[5] })

} else if (cmd === 'submit-issue') {
  const campaignId = flag('--campaign')
  const reportHash = flag('--hash')
  const api = flag('--api', false) || 'http://localhost:3000'
  const mppx = getMppxClient()

  console.error(`submitting issue to campaign ${campaignId} via ${api}...`)
  const res = await mppx.fetch(`${api}/issues`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ campaignId, reportHash }),
  })
  out(await res.json())

} else if (cmd === 'buy-yes') {
  const issueId = flag('--issue')
  const amount  = parseUnits(flag('--amount'), 6).toString()
  const api     = flag('--api', false) || 'http://localhost:3000'
  const mppx    = getMppxClient()

  console.error(`buying YES on issue ${issueId} for $${flag('--amount')} via ${api}...`)
  const res = await mppx.fetch(`${api}/issues/${issueId}/yes`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ amount }),
  })
  out(await res.json())

} else if (cmd === 'buy-no') {
  const issueId = flag('--issue')
  const amount  = parseUnits(flag('--amount'), 6).toString()
  const api     = flag('--api', false) || 'http://localhost:3000'
  const mppx    = getMppxClient()

  console.error(`buying NO on issue ${issueId} for $${flag('--amount')} via ${api}...`)
  const res = await mppx.fetch(`${api}/issues/${issueId}/no`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ amount }),
  })
  out(await res.json())

} else {
  console.log(`BountyMarket CLI

Direct contract commands (require PRIVATE_KEY):
  create-campaign  --prize-pool <usdc> --fee <usdc> --reward <usdc>
  resolve          --issue <id> --valid true|false
  claim            --issue <id>
  preview          --issue <id> [--address <addr>]

Read commands:
  campaign         --id <id>
  issue            --id <id>

MPP commands (require PRIVATE_KEY, API must be running):
  submit-issue     --campaign <id> --hash <reportHash> [--api <url>]
  buy-yes          --issue <id> --amount <usdc> [--api <url>]
  buy-no           --issue <id> --amount <usdc> [--api <url>]

Output is JSON.`)
}
