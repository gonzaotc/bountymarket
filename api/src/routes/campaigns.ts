import { Hono } from 'hono'
import { getCampaign, publicClient, BOUNTY_MARKET_ADDRESS, abi } from '../lib/chain'

const app = new Hono()

// GET /campaigns — returns all campaigns
app.get('/', async (c) => {
  const total = await publicClient.readContract({ address: BOUNTY_MARKET_ADDRESS, abi, functionName: 'nextCampaignId' }) as bigint
  const campaigns = await Promise.all(
    Array.from({ length: Number(total) }, (_, i) => BigInt(i)).map(async (id) => {
      const camp = await getCampaign(id)
      return { id: id.toString(), admin: camp[0], prizePool: camp[1].toString(), submissionFee: camp[2].toString(), rewardPerIssue: camp[3].toString(), active: camp[4] }
    })
  )
  return c.json(campaigns)
})

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

export default app
