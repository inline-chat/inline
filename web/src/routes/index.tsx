import { Navigate, createFileRoute } from "@tanstack/react-router"
import { useAuthSession } from "~/inline/auth/auth-session"
import { AppBootView } from "~/app/AppBootView"

export const Route = createFileRoute("/")({
  component: IndexRoute,
})

function IndexRoute() {
  const auth = useAuthSession()
  if (!auth.hasHydrated) return <AppBootView />
  return <Navigate to={auth.token && auth.currentUserId ? "/chats" : "/login"} replace />
}
