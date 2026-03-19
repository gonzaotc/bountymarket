import { Hono } from 'hono'
import { mppx } from '../lib/mppx'
import { getCampaign, getIssue, submitIssue, buyYes, buyNo, resolveIssue, account } from '../lib/chain'

const app = new Hono()

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
    const feeUsdc = (Number(campaign[2]) / 1e6).toFixed(6) // submissionFee

    return mppx.charge({ amount: feeUsdc, description: `Submit issue for campaign ${campaignId}` })(c.req.raw).then(
      async (result) => {
        if (result.status === 402) return result.challenge
        c.set('mppResult', result)
        c.set('campaignId', campaignId)
        await next()
      },
    )
  },
  async (c) => {
    const campaignId: bigint = c.get('campaignId')
    const receipt = await submitIssue(campaignId)

    const event = receipt.logs[0]
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
        await next()
      },
    )
  },
  async (c) => {
    const issueId = BigInt(c.req.param('id'))
    const amount: bigint = c.get('amount')
    const receipt = await buyYes(issueId, amount)

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
        await next()
      },
    )
  },
  async (c) => {
    const issueId = BigInt(c.req.param('id'))
    const amount: bigint = c.get('amount')
    const receipt = await buyNo(issueId, amount)

    const mppResult = c.get('mppResult') as any
    return mppResult.withReceipt(
      Response.json({ issueId: issueId.toString(), tx: receipt.transactionHash }),
    )
  },
)

// POST /issues/:id/resolve — admin only, no payment
// Body: { valid: boolean, adminKey: string }
app.post('/:id/resolve', async (c) => {
  const body = await c.req.json()
  if (body.adminKey !== process.env.ADMIN_KEY) {
    return c.json({ error: 'unauthorized' }, 401)
  }

  const issueId = BigInt(c.req.param('id'))
  const receipt = await resolveIssue(issueId, body.valid)

  return c.json({ issueId: issueId.toString(), valid: body.valid, tx: receipt.transactionHash })
})

export default app
