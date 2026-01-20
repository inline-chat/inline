import { useEffect, useState } from "react"
import { apiRequest } from "@/lib/api"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useAdmin } from "@/state/admin"

type OverviewMetrics = {
  dau: number
  wau: number
  messagesToday: number
  mrr: number
  connections: {
    total: number
    authenticated: number
  }
  errors: {
    last5m: number
  }
  waitlistCount: number
}

export const OverviewPage = () => {
  const { needsSetup } = useAdmin()
  const [metrics, setMetrics] = useState<OverviewMetrics | null>(null)

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      const data = await apiRequest<{ metrics: OverviewMetrics }>("/admin/metrics/overview", { method: "GET" })
      if (data.ok) {
        setMetrics(data.metrics)
      }
    }
    void load()
  }, [needsSetup])

  if (!metrics) {
    return <div className="text-xs text-muted-foreground">Loading overview...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">Overview</h2>
        <p className="text-xs text-muted-foreground">Key signals across product, ops, and pipeline.</p>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>MRR</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">${metrics.mrr}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>DAU</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.dau}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>WAU (3+ days)</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.wau}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Messages today</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.messagesToday}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Connections</CardTitle>
          </CardHeader>
          <CardContent className="text-xs">
            <div className="text-xl font-semibold">{metrics.connections.total}</div>
            <div className="text-xs text-muted-foreground">{metrics.connections.authenticated} authenticated</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Errors (5m)</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.errors.last5m}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Waitlist</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.waitlistCount}</CardContent>
        </Card>
      </div>
    </div>
  )
}
