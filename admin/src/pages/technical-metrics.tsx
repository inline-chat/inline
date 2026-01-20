import { useEffect, useState } from "react"
import { apiRequest } from "@/lib/api"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { formatBytes, formatDuration } from "@/lib/format"
import { useAdmin } from "@/state/admin"

type TechnicalMetrics = {
  server: {
    version: string
    gitCommit: string
    startedAt: string
    uptimeSeconds: number
    loadAverage: number[]
  }
  memory: {
    rss: number
    heapUsed: number
    heapTotal: number
  }
  connections: {
    total: number
    authenticated: number
    authenticatedUsers: number
    connectedToday: number
  }
  errors: {
    last5m: number
    last15m: number
    total: number
  }
}

export const TechnicalMetricsPage = () => {
  const { needsSetup } = useAdmin()
  const [metrics, setMetrics] = useState<TechnicalMetrics | null>(null)

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      const data = await apiRequest<{ metrics: TechnicalMetrics }>("/admin/metrics/technical", { method: "GET" })
      if (data.ok) {
        setMetrics(data.metrics)
      }
    }
    void load()
  }, [needsSetup])

  if (!metrics) {
    return <div className="text-xs text-muted-foreground">Loading technical metrics...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">Technical metrics</h2>
        <p className="text-xs text-muted-foreground">Live snapshot of server health.</p>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Server</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-xs">
            <div className="flex justify-between"><span className="text-muted-foreground">Version</span><span>{metrics.server.version}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Commit</span><span>{metrics.server.gitCommit}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Started</span><span>{new Date(metrics.server.startedAt).toLocaleString()}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Uptime</span><span>{formatDuration(metrics.server.uptimeSeconds)}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Load avg</span><span>{metrics.server.loadAverage.map((val) => val.toFixed(2)).join(" / ")}</span></div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Memory</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-xs">
            <div className="flex justify-between"><span className="text-muted-foreground">RSS</span><span>{formatBytes(metrics.memory.rss)}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Heap used</span><span>{formatBytes(metrics.memory.heapUsed)}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Heap total</span><span>{formatBytes(metrics.memory.heapTotal)}</span></div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Realtime connections</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-xs">
            <div className="flex justify-between"><span className="text-muted-foreground">Total</span><span>{metrics.connections.total}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Authenticated</span><span>{metrics.connections.authenticated}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Active users</span><span>{metrics.connections.authenticatedUsers}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Connected today</span><span>{metrics.connections.connectedToday}</span></div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Error rate</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-xs">
            <div className="flex justify-between"><span className="text-muted-foreground">Last 5m</span><span>{metrics.errors.last5m}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Last 15m</span><span>{metrics.errors.last15m}</span></div>
            <div className="flex justify-between"><span className="text-muted-foreground">Since start</span><span>{metrics.errors.total}</span></div>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
