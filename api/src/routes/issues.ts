import { Hono } from 'hono'
import { Credential } from 'mppx'
import { mppx } from '../lib/mppx'
import { getCampaign, getIssue, submitIssue, buyYes, buyNo, account, BOUNTY_MARKET_ADDRESS, publicClient, abi } from '../lib/chain'

const app = new Hono()

// Extracts the payer's EVM address from the MPP credential DID.
// Credential.source format: "did:pkh:eip155:4217:0xAddress"
// Falls back to the server wallet if no source is present.
function payerAddress(req: Request): `0x${string}` {
  try {
    const credential = Credential.fromRequest(req)
    const address = credential.source?.split(':').pop()
    if (address?.startsWith('0x')) return address as `0x${string}`
  } catch {}
  return account.address
}

// GET /issues — returns all issues
app.get('/', async (c) => {
  const total = await publicClient.readContract({ address: BOUNTY_MARKET_ADDRESS, abi, functionName: 'nextIssueId' }) as bigint
  const issues = await Promise.all(
    Array.from({ length: Number(total) }, (_, i) => BigInt(i)).map(async (id) => {
      const issue = await getIssue(id)
      return { id: id.toString(), campaignId: issue[0].toString(), reporter: issue[1], yesPool: issue[2].toString(), noPool: issue[3].toString(), resolved: issue[4], valid: issue[5] }
    })
  )
  return c.json(issues)
})

// GET /issues/:id — free
app.get('/:id', async (c) => {
  const id = BigInt(c.req.param('id'))
  const issue = await getIssue(id)
  return c.json({
    id: id.toString(),
    campaignId: issue[0].toString(),
    reporter: issue[1],
    yesPool: issue[2].toString(),
    noPool: issue[3].toString(),
    resolved: issue[4],
    valid: issue[5],
  })
})

// POST /issues — reporter pays submission fee F to open an issue
// Body: { campaignId: string, reportHash: string }
app.post(
  '/',
  async (c, next) => {
    const body = await c.req.json()
    const campaignId = BigInt(body.campaignId ?? '0')
    const campaign = await getCampaign(campaignId)
    const feeUsdc = (Number(campaign[2]) / 1e6).toFixed(6)

    return mppx.charge({ amount: feeUsdc, description: `Submit issue for campaign ${campaignId}` })(c.req.raw).then(
      async (result) => {
        if (result.status === 402) return result.challenge
        c.set('mppResult', result)
        c.set('campaignId', campaignId)
        c.set('payer', payerAddress(c.req.raw))
        await next()
      },
    )
  },
  async (c) => {
    const campaignId: bigint = c.get('campaignId')
    const payer: `0x${string}` = c.get('payer')
    const receipt = await submitIssue(campaignId, payer)

    const event = receipt.logs.find(l => l.address.toLowerCase() === BOUNTY_MARKET_ADDRESS.toLowerCase())!
    const issueId = BigInt(event.topics[1] ?? '0x0')

    const mppResult = c.get('mppResult') as any
    return mppResult.withReceipt(
      Response.json({ issueId: issueId.toString(), tx: receipt.transactionHash }, { status: 201 }),
    )
  },
)

// POST /issues/:id/yes — buy YES position
// Body: { amount: string } — USDC raw units (6 decimals)
app.post(
  '/:id/yes',
  async (c, next) => {
    const body = await c.req.json()
    const amount = BigInt(body.amount ?? '0')
    const amountUsdc = (Number(amount) / 1e6).toFixed(6)

    return mppx.charge({ amount: amountUsdc, description: 'Buy YES position' })(c.req.raw).then(
      async (result) => {
        if (result.status === 402) return result.challenge
        c.set('mppResult', result)
        c.set('amount', amount)
        c.set('payer', payerAddress(c.req.raw))
        await next()
      },
    )
  },
  async (c) => {
    const issueId = BigInt(c.req.param('id'))
    const amount: bigint = c.get('amount')
    const payer: `0x${string}` = c.get('payer')
    const receipt = await buyYes(issueId, amount, payer)

    const mppResult = c.get('mppResult') as any
    return mppResult.withReceipt(
      Response.json({ issueId: issueId.toString(), tx: receipt.transactionHash }),
    )
  },
)

// POST /issues/:id/no — buy NO position
// Body: { amount: string } — USDC raw units (6 decimals)
app.post(
  '/:id/no',
  async (c, next) => {
    const body = await c.req.json()
    const amount = BigInt(body.amount ?? '0')
    const amountUsdc = (Number(amount) / 1e6).toFixed(6)

    return mppx.charge({ amount: amountUsdc, description: 'Buy NO position' })(c.req.raw).then(
      async (result) => {
        if (result.status === 402) return result.challenge
        c.set('mppResult', result)
        c.set('amount', amount)
        c.set('payer', payerAddress(c.req.raw))
        await next()
      },
    )
  },
  async (c) => {
    const issueId = BigInt(c.req.param('id'))
    const amount: bigint = c.get('amount')
    const payer: `0x${string}` = c.get('payer')
    const receipt = await buyNo(issueId, amount, payer)

    const mppResult = c.get('mppResult') as any
    return mppResult.withReceipt(
      Response.json({ issueId: issueId.toString(), tx: receipt.transactionHash }),
    )
  },
)

export default app
