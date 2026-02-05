import { useEffect, useState } from "react"
import { apiRequest } from "@/lib/api"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { useAdmin } from "@/state/admin"

const StepUpPanel = ({ onDone }: { onDone: () => void }) => {
  const [password, setPassword] = useState("")
  const [totpCode, setTotpCode] = useState("")
  const [message, setMessage] = useState<string | null>(null)
  const [isBusy, setIsBusy] = useState(false)

  const submit = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest("/admin/auth/step-up", {
      method: "POST",
      body: JSON.stringify({ password, totpCode }),
    })

    if (data.ok) {
      setPassword("")
      setTotpCode("")
      onDone()
    } else {
      setMessage("Step-up failed.")
    }
    setIsBusy(false)
  }

  return (
    <Card className="border-amber-200 bg-amber-50">
      <CardHeader>
        <CardTitle className="text-base">Step-up required</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <p className="text-sm text-muted-foreground">Confirm your password and TOTP before editing users.</p>
        <Label>Password</Label>
        <Input type="password" value={password} onChange={(event) => setPassword(event.target.value)} />
        <Label>TOTP code</Label>
        <Input value={totpCode} onChange={(event) => setTotpCode(event.target.value)} placeholder="123456" />
        <Button onClick={submit} disabled={!password || !totpCode || isBusy}>
          {isBusy ? "Verifying..." : "Verify"}
        </Button>
        {message && <p className="text-sm text-muted-foreground">{message}</p>}
      </CardContent>
    </Card>
  )
}

type UserDetail = {
  user: {
    id: number
    email: string | null
    firstName: string | null
    lastName: string | null
    emailVerified: boolean | null
    avatarUrl?: string | null
  }
  sessions: Array<{
    id: number
    clientType: string | null
    clientVersion?: string | null
    osVersion?: string | null
    lastActive: string | null
    active: boolean
    deviceId: string | null
    date: string | null
    revoked?: string | null
    personalData?: {
      country?: string
      region?: string
      city?: string
      timezone?: string
      ip?: string
      deviceName?: string
    }
  }>
  connections: {
    totalConnections: number
    sessions: Array<{ sessionId: number; count: number }>
  }
}

type UserDetailPageProps = {
  userId: string
}

export const UserDetailPage = ({ userId }: UserDetailPageProps) => {
  const { needsStepUp, refresh } = useAdmin()
  const [detail, setDetail] = useState<UserDetail | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [isBusy, setIsBusy] = useState(false)
  const [showEdit, setShowEdit] = useState(false)
  const [form, setForm] = useState({
    email: "",
    firstName: "",
    lastName: "",
    emailVerified: false,
  })

  const load = async () => {
    const data = await apiRequest<UserDetail>(`/admin/users/${userId}`, { method: "GET" })
    if (data.ok) {
      setDetail(data)
      setForm({
        email: data.user.email ?? "",
        firstName: data.user.firstName ?? "",
        lastName: data.user.lastName ?? "",
        emailVerified: Boolean(data.user.emailVerified),
      })
    }
  }

  useEffect(() => {
    void load()
  }, [userId])

  const updateUser = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest(`/admin/users/${userId}/update`, {
      method: "POST",
      body: JSON.stringify({
        email: form.email,
        firstName: form.firstName,
        lastName: form.lastName,
        emailVerified: form.emailVerified,
      }),
    })

    if (data.ok) {
      await load()
      setMessage("User updated.")
      await refresh()
    } else if (data.error === "step_up_required") {
      setMessage("Step-up required before updating.")
    } else {
      setMessage("Update failed.")
    }
    setIsBusy(false)
  }

  if (!detail) {
    return <div className="text-xs text-muted-foreground">Loading user...</div>
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center gap-4">
        {detail.user.avatarUrl ? (
          <img
            src={detail.user.avatarUrl}
            alt={detail.user.email ?? "User"}
            className="h-12 w-12 rounded-full border border-border object-cover"
          />
        ) : (
          <div className="flex h-12 w-12 items-center justify-center rounded-full border border-border bg-muted text-sm font-medium text-muted-foreground">
            {(detail.user.firstName?.[0] ?? detail.user.email?.[0] ?? "U").toUpperCase()}
          </div>
        )}
        <div>
          <h2 className="text-lg font-semibold">User {detail.user.id}</h2>
          <p className="text-xs text-muted-foreground">User profile, sessions, and connections.</p>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Realtime connections</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 text-sm">
          <div className="flex items-center gap-2">
            <Badge variant="secondary">Active connections: {detail.connections.totalConnections}</Badge>
          </div>
          <div className="flex flex-wrap gap-2">
            {detail.connections.sessions.map((session) => (
              <Badge key={session.sessionId} variant="outline">
                Session {session.sessionId}: {session.count}
              </Badge>
            ))}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Sessions</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="pb-2">Session</th>
                  <th className="pb-2">Client</th>
                  <th className="pb-2">Client version</th>
                  <th className="pb-2">OS version</th>
                  <th className="pb-2">Active</th>
                  <th className="pb-2">Created</th>
                  <th className="pb-2">Last active</th>
                  <th className="pb-2">Revoked</th>
                  <th className="pb-2">Device</th>
                  <th className="pb-2">Location</th>
                  <th className="pb-2">IP</th>
                </tr>
              </thead>
              <tbody>
                {detail.sessions.map((session) => (
                  <tr key={session.id} className="border-t border-border">
                    <td className="py-2">{session.id}</td>
                    <td className="py-2">{session.clientType ?? "N/A"}</td>
                    <td className="py-2">{session.clientVersion ?? "N/A"}</td>
                    <td className="py-2">{session.osVersion ?? "N/A"}</td>
                    <td className="py-2">{session.active ? "Yes" : "No"}</td>
                    <td className="py-2">{session.date ? new Date(session.date).toLocaleString() : "N/A"}</td>
                    <td className="py-2">
                      {session.lastActive ? new Date(session.lastActive).toLocaleString() : "N/A"}
                    </td>
                    <td className="py-2">{session.revoked ? new Date(session.revoked).toLocaleString() : "N/A"}</td>
                    <td className="py-2">{session.personalData?.deviceName ?? session.deviceId ?? "N/A"}</td>
                    <td className="py-2">
                      <div>
                        {[session.personalData?.city, session.personalData?.region, session.personalData?.country]
                          .filter(Boolean)
                          .join(", ") || "N/A"}
                      </div>
                      {session.personalData?.timezone && (
                        <div className="text-[11px] text-muted-foreground">{session.personalData.timezone}</div>
                      )}
                    </td>
                    <td className="py-2">{session.personalData?.ip ?? "N/A"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle>Edit user</CardTitle>
          <Button variant="outline" onClick={() => setShowEdit((prev) => !prev)}>
            {showEdit ? "Hide edit" : "Edit user"}
          </Button>
        </CardHeader>
        {showEdit && (
          <CardContent className="grid gap-4 md:grid-cols-2 pt-4">
            <div className="space-y-2">
              <Label>Email</Label>
              <Input value={form.email} onChange={(event) => setForm({ ...form, email: event.target.value })} />
            </div>
            <div className="space-y-2">
              <Label>Email verified</Label>
              <select
                className="h-10 w-full rounded-[var(--radius)] border border-input bg-background px-3 text-sm"
                value={form.emailVerified ? "yes" : "no"}
                onChange={(event) => setForm({ ...form, emailVerified: event.target.value === "yes" })}
              >
                <option value="yes">Yes</option>
                <option value="no">No</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label>First name</Label>
              <Input value={form.firstName} onChange={(event) => setForm({ ...form, firstName: event.target.value })} />
            </div>
            <div className="space-y-2">
              <Label>Last name</Label>
              <Input value={form.lastName} onChange={(event) => setForm({ ...form, lastName: event.target.value })} />
            </div>
            <div className="md:col-span-2 flex items-center gap-3">
              <Button onClick={updateUser} disabled={isBusy || needsStepUp}>
                {isBusy ? "Saving..." : "Save changes"}
              </Button>
              {message && <span className="text-sm text-muted-foreground">{message}</span>}
            </div>
          </CardContent>
        )}
      </Card>

      {needsStepUp && <StepUpPanel onDone={refresh} />}
    </div>
  )
}
