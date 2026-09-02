import { createFileRoute } from "@tanstack/react-router"
import { LandingRoute } from "../../landing/public-beta/LandingRoute"
import { landingHead } from "../../landing/public-beta/seo"

function BetaHome() {
  return <LandingRoute locale="en" />
}

export const Route = createFileRoute("/beta/")({
  component: BetaHome,
  head: () => landingHead("en"),
})
