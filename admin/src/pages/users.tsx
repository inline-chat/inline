import { useEffect, useState } from "react"
import { Link } from "@tanstack/react-router"
import { apiRequest } from "@/lib/api"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { useAdmin } from "@/state/admin"

type UserRow = {
  id: number
  email: string | null
  firstName: string | null
  lastName: string | null
  emailVerified: boolean | null
  avatarUrl?: string | null
  username?: string | null
  phoneNumber?: string | null
  online?: boolean | null
  lastOnline?: string | null
  createdAt?: string | null
  deleted?: boolean | null
  bot?: boolean | null
}

export const UsersPage = () => {
  const { needsSetup } = useAdmin()
  const [query, setQuery] = useState("")
  const [users, setUsers] = useState<UserRow[]>([])
  const [isLoading, setIsLoading] = useState(true)

  useEffect(() => {
    if (needsSetup) return
    const load = async () => {
      setIsLoading(true)
      const data = await apiRequest<{ users: UserRow[] }>(
        `/admin/users?query=${encodeURIComponent(query)}`,
        { method: "GET" },
      )
      if (data.ok) {
        setUsers(data.users)
      }
      setIsLoading(false)
    }
    void load()
  }, [needsSetup, query])

  if (isLoading && !query) {
    return <div className="text-xs text-muted-foreground">Loading users...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">Users</h2>
        <p className="text-xs text-muted-foreground">Search and inspect user sessions.</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Directory</CardTitle>
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
                  <th className="pb-2">User</th>
                  <th className="pb-2">Status</th>
                  <th className="pb-2">Username</th>
                  <th className="pb-2">Phone</th>
                  <th className="pb-2">Name</th>
                  <th className="pb-2">Email verified</th>
                  <th className="pb-2">Created</th>
                  <th className="pb-2">Last online</th>
                </tr>
              </thead>
              <tbody>
                {users.map((user) => (
                  <tr key={user.id} className="border-t border-border">
                    <td className="py-2">
                      <div className="flex items-center gap-3">
                        {user.avatarUrl ? (
                          <img
                            src={user.avatarUrl}
                            alt={user.email ?? "User"}
                            className="h-8 w-8 rounded-full border border-border object-cover"
                          />
                        ) : (
                          <div className="flex h-8 w-8 items-center justify-center rounded-full border border-border bg-muted text-[11px] font-medium text-muted-foreground">
                            {(user.firstName?.[0] ?? user.email?.[0] ?? "U").toUpperCase()}
                          </div>
                        )}
                        <div className="flex flex-col">
                          <Link
                            to="/users/$userId"
                            params={{ userId: String(user.id) }}
                            className="text-primary"
                          >
                            {user.email ?? "N/A"}
                          </Link>
                          <span className="text-[11px] text-muted-foreground">ID {user.id}</span>
                        </div>
                      </div>
                    </td>
                    <td className="py-2">
                      {user.deleted ? (
                        <span className="text-[11px] text-muted-foreground">Deleted</span>
                      ) : (
                        <span className={user.online ? "text-emerald-600" : "text-muted-foreground"}>
                          {user.online ? "Online" : "Offline"}
                        </span>
                      )}
                      {user.bot && <div className="text-[11px] text-muted-foreground">Bot</div>}
                    </td>
                    <td className="py-2">{user.username ?? "-"}</td>
                    <td className="py-2">{user.phoneNumber ?? "-"}</td>
                    <td className="py-2">{[user.firstName, user.lastName].filter(Boolean).join(" ") || "N/A"}</td>
                    <td className="py-2">{user.emailVerified ? "Yes" : "No"}</td>
                    <td className="py-2">{user.createdAt ? new Date(user.createdAt).toLocaleDateString() : "-"}</td>
                    <td className="py-2">{user.lastOnline ? new Date(user.lastOnline).toLocaleString() : "-"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!isLoading && users.length === 0 && (
              <div className="py-6 text-xs text-muted-foreground">No users found.</div>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
