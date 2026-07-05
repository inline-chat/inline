import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"

export const Route = createFileRoute("/docs/roadmap")({
  component: RoadmapDocs,
  head: () => docsPageHead("roadmap"),
})

function RoadmapDocs() {
  return <DocsPage slug="roadmap" />
}
