import { createFileRoute } from "@tanstack/react-router"
import { SpacesPage } from "@/pages/spaces"

export const Route = createFileRoute("/_app/spaces")({
  component: SpacesPage,
})
