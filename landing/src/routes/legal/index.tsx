import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import legal from "~/legal/content/index.md?raw"

export const Route = createFileRoute("/legal/")({
  component: LegalIndex,
  head: () => ({
    meta: [{ title: "Legal - Inline" }],
  }),
})

function LegalIndex() {
  return <DocsMarkdown markdown={legal} className="page-content docs-content legal-content" />
}
