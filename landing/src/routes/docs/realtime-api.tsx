import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import realtimeApi from "~/docs/content/realtime-api.md?raw"

export const Route = createFileRoute("/docs/realtime-api")({
  component: RealtimeApiDocs,
  head: () => ({
    meta: [{ title: "Realtime API - Inline Docs" }],
  }),
})

function RealtimeApiDocs() {
  return <DocsMarkdown markdown={realtimeApi} className="page-content docs-content" />
}
