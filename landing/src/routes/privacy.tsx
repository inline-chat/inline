import { createFileRoute, redirect } from "@tanstack/react-router"

export const Route = createFileRoute("/privacy")({
  loader: () => {
    throw redirect({ href: "/legal/privacy" })
  },
})
