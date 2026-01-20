import { createFileRoute } from "@tanstack/react-router"
import { TechnicalMetricsPage } from "@/pages/technical-metrics"

export const Route = createFileRoute("/_app/metrics/technical")({
  component: TechnicalMetricsPage,
})
