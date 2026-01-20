import { createFileRoute } from "@tanstack/react-router"
import { AppMetricsPage } from "@/pages/app-metrics"

export const Route = createFileRoute("/_app/metrics/app")({
  component: AppMetricsPage,
})
