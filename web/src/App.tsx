import React, { useEffect, useState, useCallback } from 'react'
import { client, CONTRACT, abi, fmt, shortAddr } from './chain'

const API = 'https://bountymarket.up.railway.app'

type Campaign = {
  id: string
  admin: string
  prizePool: string
  submissionFee: string
  rewardPerIssue: string
  active: boolean
}

type Issue = {
  id: string
  campaignId: string
  reporter: string
  yesPool: string
  noPool: string
  resolved: boolean
  valid: boolean
}

async function fetchAll() {
  const [campaigns, issues] = await Promise.all([
    fetch(`${API}/campaigns`).then(r => r.json()) as Promise<Campaign[]>,
    fetch(`${API}/issues`).then(r => r.json()) as Promise<Issue[]>,
  ])
  return { campaigns, issues }
}

export default function App() {
  const [campaigns, setCampaigns] = useState<Campaign[]>([])
  const [issues, setIssues] = useState<Issue[]>([])
  const [lastUpdate, setLastUpdate] = useState<Date>(new Date())
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    const data = await fetchAll()
    setCampaigns(data.campaigns)
    setIssues(data.issues)
    setLastUpdate(new Date())
    setLoading(false)
  }, [])

  useEffect(() => {
    refresh()

    const events = ['CampaignCreated', 'IssueSubmitted', 'IssueResolved', 'YesBought', 'NoBought'] as const
    const unwatchers = events.map((eventName) =>
      client.watchContractEvent({
        address: CONTRACT,
        abi,
        eventName,
        onLogs: () => refresh(),
      })
    )

    return () => unwatchers.forEach((unwatch) => unwatch())
  }, [refresh])

  return (
    <div className="app">
      <header>
        <h1>BountyMarket</h1>
        <span className="subtitle">
          {loading ? 'loading…' : `${campaigns.length} campaigns · ${issues.length} issues · updated ${lastUpdate.toLocaleTimeString()}`}
        </span>
      </header>

      <section>
        <h2>Campaigns</h2>
        {campaigns.length === 0 && !loading ? (
          <p className="empty">No campaigns yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Admin</th>
                <th>Prize Pool</th>
                <th>Sub Fee</th>
                <th>Reward / Issue</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {campaigns.map((c) => (
                <tr key={c.id}>
                  <td>{c.id}</td>
                  <td className="mono">{shortAddr(c.admin)}</td>
                  <td>{fmt(c.prizePool)}</td>
                  <td>{fmt(c.submissionFee)}</td>
                  <td>{fmt(c.rewardPerIssue)}</td>

                  <td>
                    <span className={c.active ? 'badge active' : 'badge inactive'}>
                      {c.active ? 'active' : 'closed'}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section>
        <h2>Issues</h2>
        {issues.length === 0 && !loading ? (
          <p className="empty">No issues yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Campaign</th>
                <th>Reporter</th>
                <th>YES Pool</th>
                <th>NO Pool</th>
                <th>Market</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {issues.map((issue) => {
                const yes = Number(issue.yesPool)
                const no = Number(issue.noPool)
                const yesPct = yes + no > 0 ? Math.round((yes / (yes + no)) * 100) : 50
                return (
                  <tr key={issue.id}>
                    <td>{issue.id}</td>
                    <td>{issue.campaignId.toString()}</td>
                    <td className="mono">{shortAddr(issue.reporter)}</td>
                    <td>{fmt(issue.yesPool)}</td>
                    <td>{fmt(issue.noPool)}</td>
                    <td>
                      <div className="market-bar" title={`YES ${yesPct}% / NO ${100 - yesPct}%`}>
                        <div className="yes-fill" style={{ width: `${yesPct}%` }} />
                        <span className="bar-label">{yesPct}% YES</span>
                      </div>
                    </td>
                    <td>
                      {issue.resolved ? (
                        <span className={issue.valid ? 'badge valid' : 'badge invalid'}>
                          {issue.valid ? 'valid' : 'invalid'}
                        </span>
                      ) : (
                        <span className="badge pending">pending</span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </section>
    </div>
  )
}
