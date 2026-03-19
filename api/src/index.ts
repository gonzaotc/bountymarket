import { Hono } from 'hono'
import campaigns from './routes/campaigns'
import issues from './routes/issues'

const app = new Hono()

app.get('/', (c) =>
  c.json({
    name: 'BountyMarket API',
    description: 'Pay-to-submit bug bounty platform with prediction markets on issue validity.',
    note: 'Companies interact with the contract directly. This API is the MPP payment gateway for reporters and traders.',
    contract: '0x34471e7266d9dc3dc350ad6dee07120acb9c8721',
    endpoints: {
      'GET  /campaigns/:id': 'Get campaign details (free)',
      'GET  /issues/:id':    'Get issue + market state (free)',
      'POST /issues':        'Submit issue — MPP payment = submission fee F',
      'POST /issues/:id/yes':'Buy YES position — MPP payment = bet amount',
      'POST /issues/:id/no': 'Buy NO position — MPP payment = bet amount',
    },
  }),
)

app.route('/campaigns', campaigns)
app.route('/issues', issues)

export default {
  port: process.env.PORT ? parseInt(process.env.PORT) : 3000,
  fetch: app.fetch,
}

console.log(`BountyMarket API running on http://localhost:${process.env.PORT ?? 3000}`)
