import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useAdmin } from "@/state/admin"

export const SettingsPage = () => {
  const { session } = useAdmin()

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-lg font-semibold">Settings</h2>
        <p className="text-xs text-muted-foreground">Basic admin configuration snapshot.</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Current admin</CardTitle>
        </CardHeader>
        <CardContent className="text-xs text-muted-foreground">
          <div>Email: {session?.user.email}</div>
          <div>User ID: {session?.user.id}</div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Notes</CardTitle>
        </CardHeader>
        <CardContent className="text-xs text-muted-foreground">
          This page will grow with configuration options (feature flags, ops toggles, notifications).
        </CardContent>
      </Card>
    </div>
  )
}
