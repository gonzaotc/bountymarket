import { Hono } from 'hono'
import campaigns from './routes/campaigns'
import issues from './routes/issues'

const app = new Hono()

app.get('/', (c) =>
  c.json({
    name: 'BountyMarket API',
    description: 'Pay-to-submit bug bounty platform with prediction markets on issue validity.',
    endpoints: {
      'GET  /campaigns/:id': 'Get campaign details (free)',
      'POST /campaigns': 'Create campaign — MPP payment = prize pool',
      'GET  /issues/:id': 'Get issue + market state (free)',
      'POST /issues': 'Submit issue — MPP payment = submission fee F',
      'POST /issues/:id/yes': 'Buy YES position — MPP payment = bet amount',
      'POST /issues/:id/no': 'Buy NO position — MPP payment = bet amount',
      'POST /issues/:id/resolve': 'Resolve issue (admin only)',
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
