import { Hono } from 'hono'
import { mppx } from '../lib/mppx'
import { createCampaign, getCampaign } from '../lib/chain'

const app = new Hono()

// GET /campaigns/:id — free, returns campaign state
app.get('/:id', async (c) => {
  const id = BigInt(c.req.param('id'))
  const campaign = await getCampaign(id)
  return c.json({
    id: id.toString(),
    admin: campaign[0],
    prizePool: campaign[1].toString(),
    submissionFee: campaign[2].toString(),
    rewardPerIssue: campaign[3].toString(),
    active: campaign[4],
  })
})

// POST /campaigns — paid: company sends prize pool + 1% fee via MPP
// Body: { prizePool: string, submissionFee: string, rewardPerIssue: string }
// MPP charge = prizePool (the server relays + approves USDC on-chain)
app.post(
  '/',
  async (c, next) => {
    const body = await c.req.json()
    const prizePool = BigInt(body.prizePool ?? '0')
    // Charge in USDC units (6 decimals) — prizePool is already in raw units
    const amountUsdc = (Number(prizePool) / 1e6).toFixed(6)
    return mppx.charge({ amount: amountUsdc, description: 'Create bounty campaign' })(c.req.raw).then(
      async (result) => {
        if (result.status === 402) {
          return result.challenge
        }
        c.set('mppResult', result)
        await next()
      },
    )
  },
  async (c) => {
    const body = await c.req.json()
    const prizePool = BigInt(body.prizePool)
    const submissionFee = BigInt(body.submissionFee)
    const rewardPerIssue = BigInt(body.rewardPerIssue)

    const receipt = await createCampaign(prizePool, submissionFee, rewardPerIssue)

    // Extract campaignId from CampaignCreated event
    const event = receipt.logs[0]
    const campaignId = BigInt(event.topics[1] ?? '0x0')

    const mppResult = c.get('mppResult') as any
    return mppResult.withReceipt(
      Response.json({ campaignId: campaignId.toString(), tx: receipt.transactionHash }, { status: 201 }),
    )
  },
)

export default app
