import { useEffect, useState } from "react"
import { apiRequest } from "@/lib/api"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useAdmin } from "@/state/admin"

type AppMetrics = {
  dau: number
  wau: number
  messagesToday: number
  activeUsersToday: number
  activeUsersLast7d: number
  totals: {
    totalUsers: number
    verifiedUsers: number
    onlineUsers: number
  }
}

export const AppMetricsPage = () => {
  const { needsSetup } = useAdmin()
  const [metrics, setMetrics] = useState<AppMetrics | null>(null)

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      const data = await apiRequest<{ metrics: AppMetrics }>("/admin/metrics/app", { method: "GET" })
      if (data.ok) {
        setMetrics(data.metrics)
      }
    }
    void load()
  }, [needsSetup])

  if (!metrics) {
    return <div className="text-xs text-muted-foreground">Loading app metrics...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">App metrics</h2>
        <p className="text-xs text-muted-foreground">Activity based on message sends.</p>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Monthly recurring revenue</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">$390</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Daily active users</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.dau}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Weekly active users (3+ days)</CardTitle>
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
            <CardTitle>Active users today</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.activeUsersToday}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Active users last 7d</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.activeUsersLast7d}</CardContent>
        </Card>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Total users</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.totals.totalUsers}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Verified users</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.totals.verifiedUsers}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Online users</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{metrics.totals.onlineUsers}</CardContent>
        </Card>
      </div>
    </div>
  )
}
