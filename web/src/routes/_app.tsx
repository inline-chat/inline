import { Navigate, createFileRoute } from "@tanstack/react-router"
import { AppShell } from "~/app/AppShell"
import { AppBootView } from "~/app/AppBootView"
import { useAuthSession } from "~/inline/auth/auth-session"
import { InlineRuntime } from "~/inline/runtime/InlineRuntime"

export const Route = createFileRoute("/_app")({
  component: AuthenticatedApp,
})

function AuthenticatedApp() {
  const auth = useAuthSession()
  if (!auth.hasHydrated) return <AppBootView />
  if (!auth.token || auth.currentUserId == null) return <Navigate to="/login" replace />

  return (
    <InlineRuntime userId={auth.currentUserId}>
      <AppShell />
    </InlineRuntime>
  )
}
