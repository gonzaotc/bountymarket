import { Hono } from 'hono'
import { getCampaign } from '../lib/chain'

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

export default app
