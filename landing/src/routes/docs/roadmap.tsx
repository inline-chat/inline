import { createFileRoute } from "@tanstack/react-router"
import { DocsPage, docsPageHead } from "~/docs/DocsPage"
import { requireDocsPage } from "~/docs/pages"

export const Route = createFileRoute("/docs/roadmap")({
  loader: () => {
    requireDocsPage("roadmap")
  },
  component: RoadmapDocs,
  head: () => docsPageHead("roadmap"),
})

function RoadmapDocs() {
  return <DocsPage slug="roadmap" />
}
