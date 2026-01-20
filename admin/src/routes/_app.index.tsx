import { createFileRoute } from "@tanstack/react-router"
import { OverviewPage } from "@/pages/overview"

export const Route = createFileRoute("/_app/")({
  component: OverviewPage,
})
