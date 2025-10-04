import { createFileRoute, redirect } from "@tanstack/react-router"

export const Route = createFileRoute("/feedback")({
  loader: () => {
    throw redirect({ href: "https://inlinehq.notion.site/14b361a8824f80bba76dc53046aa4efc?pvs=105" })
  },
})
