import { useEffect, useState } from "react"
import { apiRequest } from "@/lib/api"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { useAdmin } from "@/state/admin"

type WaitlistEntry = {
  id: number
  email: string
  name: string | null
  verified: boolean
  date: string | null
}

type WaitlistResponse = {
  count: number
  entries: WaitlistEntry[]
}

export const WaitlistPage = () => {
  const { needsSetup } = useAdmin()
  const [query, setQuery] = useState("")
  const [data, setData] = useState<WaitlistResponse | null>(null)

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      const url = `/admin/waitlist?query=${encodeURIComponent(query)}`
      const response = await apiRequest<WaitlistResponse>(url, { method: "GET" })
      if (response.ok) {
        setData({ count: response.count, entries: response.entries })
      }
    }
    void load()
  }, [needsSetup, query])

  if (!data) {
    return <div className="text-xs text-muted-foreground">Loading waitlist...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">Waitlist</h2>
        <p className="text-xs text-muted-foreground">{data.count} total signups</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Members</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="mb-4">
            <Input
              placeholder="Search by email or name"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="pb-2">Email</th>
                  <th className="pb-2">Name</th>
                  <th className="pb-2">Verified</th>
                  <th className="pb-2">Joined</th>
                </tr>
              </thead>
              <tbody>
                {data.entries.map((entry) => (
                  <tr key={entry.id} className="border-t border-border">
                    <td className="py-2 font-medium text-foreground">{entry.email}</td>
                    <td className="py-2">{entry.name ?? "-"}</td>
                    <td className="py-2">{entry.verified ? "Yes" : "No"}</td>
                    <td className="py-2">
                      {entry.date ? new Date(entry.date).toLocaleDateString() : "-"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {data.entries.length === 0 && (
              <div className="py-6 text-xs text-muted-foreground">No waitlist entries found.</div>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
