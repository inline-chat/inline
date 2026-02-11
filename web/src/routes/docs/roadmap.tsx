import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import roadmap from "~/docs/content/roadmap.md?raw"

export const Route = createFileRoute("/docs/roadmap")({
  component: RoadmapDocs,
  head: () => ({
    meta: [{ title: "Roadmap - Inline Docs" }],
  }),
})

function RoadmapDocs() {
  return <DocsMarkdown markdown={roadmap} className="page-content docs-content" />
}

