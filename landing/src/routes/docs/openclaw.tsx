import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import openclaw from "~/docs/content/openclaw.md?raw"

export const Route = createFileRoute("/docs/openclaw")({
  component: OpenClawDocs,
  head: () => ({
    meta: [{ title: "OpenClaw - Inline Docs" }],
  }),
})

function OpenClawDocs() {
  return <DocsMarkdown markdown={openclaw} className="page-content docs-content" />
}
