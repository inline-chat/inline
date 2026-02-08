import { useEffect, useState } from "react"
import { apiRequest } from "@/lib/api"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { useAdmin } from "@/state/admin"

type SpaceRow = {
  id: number
  name: string
  handle: string | null
  createdAt: string | null
  lastUpdateDate: string | null
  memberCount: number
}

type SpaceThreadsTodayRow = {
  spaceId: number
  name: string
  handle: string | null
  threadsCreatedToday: number
}

type SpaceThreadsTodayMetrics = {
  startOfDayUtc: string
  nextDayUtc: string
  spaces: SpaceThreadsTodayRow[]
}

export const SpacesPage = () => {
  const { needsSetup } = useAdmin()
  const [query, setQuery] = useState("")
  const [spaces, setSpaces] = useState<SpaceRow[]>([])
  const [threadsToday, setThreadsToday] = useState<SpaceThreadsTodayMetrics | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [isThreadsLoading, setIsThreadsLoading] = useState(true)

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      setIsThreadsLoading(true)
      const data = await apiRequest<{ metrics: SpaceThreadsTodayMetrics }>("/admin/metrics/spaces", { method: "GET" })
      if (data.ok) {
        setThreadsToday(data.metrics)
      }
      setIsThreadsLoading(false)
    }
    void load()
  }, [needsSetup])

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      setIsLoading(true)
      const data = await apiRequest<{ spaces: SpaceRow[] }>(
        `/admin/spaces?query=${encodeURIComponent(query)}`,
        { method: "GET" },
      )
      if (data.ok) {
        setSpaces(data.spaces)
      }
      setIsLoading(false)
    }
    void load()
  }, [needsSetup, query])

  if (isLoading && !query) {
    return <div className="text-xs text-muted-foreground">Loading spaces...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">Spaces</h2>
        <p className="text-xs text-muted-foreground">Sorted by most members.</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Threads created today</CardTitle>
        </CardHeader>
        <CardContent>
          {isThreadsLoading && !threadsToday ? (
            <div className="text-xs text-muted-foreground">Loading space thread metrics...</div>
          ) : threadsToday && threadsToday.spaces.length > 0 ? (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="pb-2">Name</th>
                    <th className="pb-2">Handle</th>
                    <th className="pb-2">Threads</th>
                  </tr>
                </thead>
                <tbody>
                  {threadsToday.spaces.slice(0, 50).map((space) => (
                    <tr key={space.spaceId} className="border-t border-border">
                      <td className="py-2 font-medium text-foreground">{space.name}</td>
                      <td className="py-2">{space.handle ?? "-"}</td>
                      <td className="py-2">{space.threadsCreatedToday}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="text-xs text-muted-foreground">No threads created today.</div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Directory</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="mb-4">
            <Input
              placeholder="Search by name or handle"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="pb-2">Name</th>
                  <th className="pb-2">Handle</th>
                  <th className="pb-2">Members</th>
                  <th className="pb-2">Created</th>
                  <th className="pb-2">Last update</th>
                </tr>
              </thead>
              <tbody>
                {spaces.map((space) => (
                  <tr key={space.id} className="border-t border-border">
                    <td className="py-2 font-medium text-foreground">{space.name}</td>
                    <td className="py-2">{space.handle ?? "-"}</td>
                    <td className="py-2">{space.memberCount}</td>
                    <td className="py-2">{space.createdAt ? new Date(space.createdAt).toLocaleDateString() : "-"}</td>
                    <td className="py-2">
                      {space.lastUpdateDate ? new Date(space.lastUpdateDate).toLocaleDateString() : "-"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!isLoading && spaces.length === 0 && (
              <div className="py-6 text-xs text-muted-foreground">No spaces found.</div>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
