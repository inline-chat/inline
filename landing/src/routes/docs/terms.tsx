import { createFileRoute, redirect } from "@tanstack/react-router"

export const Route = createFileRoute("/docs/terms")({
  loader: () => {
    throw redirect({ href: "/legal/terms" })
  },
})
