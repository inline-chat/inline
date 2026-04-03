import { createFileRoute } from "@tanstack/react-router"
import { DocsMarkdown } from "~/docs/DocsMarkdown"

import security from "~/docs/content/security.md?raw"

export const Route = createFileRoute("/docs/security")({
  component: SecurityDocs,
  head: () => ({
    meta: [{ title: "Security - Inline Docs" }],
  }),
})

function SecurityDocs() {
  return <DocsMarkdown markdown={security} className="page-content docs-content" />
}

