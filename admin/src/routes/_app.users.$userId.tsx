import { createFileRoute } from "@tanstack/react-router"
import { UserDetailPage } from "@/pages/user-detail"

const UserDetailRoute = () => {
  const { userId } = Route.useParams()
  return <UserDetailPage userId={userId} />
}

export const Route = createFileRoute("/_app/users/$userId")({
  component: UserDetailRoute,
})
