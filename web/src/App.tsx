import React, { useEffect, useState, useCallback } from 'react'
import { client, CONTRACT, abi, fmt, shortAddr } from './chain'

type Campaign = {
  id: number
  admin: string
  prizePool: bigint
  submissionFee: bigint
  rewardPerIssue: bigint
  active: boolean
}

type Issue = {
  id: number
  campaignId: bigint
  reporter: string
  yesPool: bigint
  noPool: bigint
  resolved: boolean
  valid: boolean
}

async function fetchAll() {
  const [nextCampaign, nextIssue] = await Promise.all([
    client.readContract({ address: CONTRACT, abi, functionName: 'nextCampaignId' }) as Promise<bigint>,
    client.readContract({ address: CONTRACT, abi, functionName: 'nextIssueId' }) as Promise<bigint>,
  ])

  const campaignIds = Array.from({ length: Number(nextCampaign) }, (_, i) => i)
  const issueIds = Array.from({ length: Number(nextIssue) }, (_, i) => i)

  const [rawCampaigns, rawIssues] = await Promise.all([
    Promise.all(
      campaignIds.map((id) =>
        client.readContract({ address: CONTRACT, abi, functionName: 'campaigns', args: [BigInt(id)] }) as Promise<[string, bigint, bigint, bigint, boolean]>
      )
    ),
    Promise.all(
      issueIds.map((id) =>
        client.readContract({ address: CONTRACT, abi, functionName: 'issues', args: [BigInt(id)] }) as Promise<[bigint, string, bigint, bigint, boolean, boolean]>
      )
    ),
  ])

  const campaigns: Campaign[] = rawCampaigns.map(([admin, prizePool, submissionFee, rewardPerIssue, active], i) => ({
    id: i, admin, prizePool, submissionFee, rewardPerIssue, active,
  }))

  const issues: Issue[] = rawIssues.map(([campaignId, reporter, yesPool, noPool, resolved, valid], i) => ({
    id: i, campaignId, reporter, yesPool, noPool, resolved, valid,
  }))

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
                const total = issue.yesPool + issue.noPool
                const yesPct = total > 0n ? Math.round((Number(issue.yesPool) / Number(total)) * 100) : 50
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
