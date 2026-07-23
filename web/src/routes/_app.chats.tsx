import { createFileRoute } from "@tanstack/react-router"
import { AllChatsView } from "~/chats/AllChatsView"

type AllChatsRouteSearch = {
  archived?: true
}

export const Route = createFileRoute("/_app/chats")({
  validateSearch: (
    search: Record<string, unknown>,
  ): AllChatsRouteSearch => ({
    archived:
      search.archived === true || search.archived === "true"
        ? true
        : undefined,
  }),
  component: AllChatsRoute,
  head: () => ({
    meta: [{ title: "All Chats · Inline" }],
  }),
})

function AllChatsRoute() {
  const search = Route.useSearch()
  const navigate = Route.useNavigate()
  return (
    <AllChatsView
      archived={search.archived === true}
      onArchivedChange={(archived) => {
        void navigate({
          search: archived ? { archived: true } : {},
        })
      }}
    />
  )
}
